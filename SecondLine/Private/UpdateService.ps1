# The one update service: Show-SLHelp, Invoke-SLUpdateCheck, Get-SLUpdateStatus
# and the opt-in profile block all use it.
#
# One cache per user per machine (LocalApplicationData\SecondLine, or
# SECONDLINE_CACHE_DIR), shared by every session and project:
#   update-cache.json  lookup results, failure backoff, last notice shown (atomic writes)
#   update-cache.lock  held during a lookup, so concurrent sessions don't repeat it
#   next-check.txt     UTC ticks of the next due lookup; the profile block reads only this
#   notice.txt         a pending notice for the next interactive shell (profile block)
#
# Lookups query only the PowerShell Gallery, only for SecondLine, stable releases by
# default, with a short timeout and bounded retries. Nothing is ever installed.

$script:SLUpdateDefaults = @{
    Enabled               = $true
    RefreshHours          = 24
    TimeoutSeconds        = 3
    Retries               = 1
    IncludePrerelease     = $false
    FailureBackoffMinutes = 60
}
$script:SLUpdateLimits = @{
    RefreshHours          = @(1, 720)
    TimeoutSeconds        = @(1, 30)
    Retries               = @(0, 3)
    FailureBackoffMinutes = @(1, 1440)
}
$script:SLCacheSchema = 1
# A lock older than this belongs to a process that died without cleaning up.
$script:SLLockStaleMinutes = 2

# ---------------------------------------------------------------- settings --

# Problems with one Updates section, as strings.
function Test-SLUpdateSettings {
    param($Settings, [string] $Label)
    if ($Settings -isnot [hashtable]) { return "$Label must be @{ RefreshHours = 24; ... }." }
    foreach ($key in $Settings.Keys) {
        $value = $Settings[$key]
        if (-not $script:SLUpdateDefaults.ContainsKey($key)) {
            "$Label has an unknown key '$key'. Use: $((@($script:SLUpdateDefaults.Keys) | Sort-Object) -join ', ')."
        }
        elseif ($key -in 'Enabled', 'IncludePrerelease') {
            if ($value -isnot [bool]) { "$Label.$key must be `$true or `$false." }
        }
        else {
            $range = $script:SLUpdateLimits[$key]
            $n = 0
            if (-not [int]::TryParse("$value", [ref] $n) -or $n -lt $range[0] -or $n -gt $range[1]) {
                "$Label.$key must be a whole number from $($range[0]) to $($range[1])."
            }
        }
    }
}

# Effective update settings, each with its source. Precedence, lowest first:
# defaults, the project chain (root to nearest), machine, user. Update notices are a
# personal preference, so here the user has the last word. They never change a
# project's approved version, which comes only from ModuleVersions. In CI, or with
# SECONDLINE_NO_UPDATE_CHECK=1, checks are off.
function Get-SLUpdateSettings {
    param([string] $Standard, [string] $Directory, [switch] $NoHostSettings)
    $layers = @([pscustomobject]@{ Source = 'default'; Data = @{ Updates = $script:SLUpdateDefaults } })
    $layers += @(Get-SLProjectSettingsLayer -Standard $Standard -Directory $Directory -DevelopmentPath $script:SLDevelopmentStandard)
    foreach ($h in @(Get-SLHostSettingsLayer -NoHostSettings:$NoHostSettings)) {
        $layers += [pscustomobject]@{ Source = "$($h.Scope.ToLowerInvariant()) $($h.Path)"; Data = $h.Data }
    }
    foreach ($layer in $layers) {
        if (-not $layer.Data.ContainsKey('Updates')) { continue }
        $problems = @(Test-SLUpdateSettings -Settings $layer.Data.Updates -Label "Updates in $($layer.Source)")
        if ($problems.Count -gt 0) { throw ($problems -join ' ') }
    }
    $effective = Merge-SLSettingLayer -Layers $layers -Section 'Updates'
    $off = $null
    if ($env:SECONDLINE_NO_UPDATE_CHECK -eq '1') { $off = 'SECONDLINE_NO_UPDATE_CHECK=1' }
    elseif (Test-SLCIEnvironment) { $off = 'CI environment' }
    if ($off) {
        $prior = $effective['Enabled']
        $effective['Enabled'] = [pscustomobject]@{ Name = 'Enabled'; Value = $false; Source = $off; Overridden = @([pscustomobject]@{ Value = $prior.Value; Source = $prior.Source }) }
    }
    return $effective
}

# Plain values (name -> value) from Get-SLUpdateSettings.
function ConvertTo-SLUpdateOptions {
    param([hashtable] $Settings)
    $options = @{}
    foreach ($key in $Settings.Keys) { $options[$key] = $Settings[$key].Value }
    return $options
}

# ------------------------------------------------------------------- cache --

function Get-SLCacheDirectory {
    if ($env:SECONDLINE_CACHE_DIR) { return $env:SECONDLINE_CACHE_DIR }
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SecondLine')
}

# The cache, or an empty one if the file is missing, unreadable, or from another schema.
function Read-SLUpdateCache {
    $empty = [pscustomobject]@{ SchemaVersion = $script:SLCacheSchema; Entries = [pscustomobject]@{}; NoticeShown = '' }
    $file = Join-Path (Get-SLCacheDirectory) 'update-cache.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $empty }
    try {
        $cache = [IO.File]::ReadAllText($file) | ConvertFrom-Json -ErrorAction Stop
        if ($cache.SchemaVersion -ne $script:SLCacheSchema -or $null -eq $cache.Entries) { return $empty }
        if ($null -eq $cache.PSObject.Properties['NoticeShown']) { $cache | Add-Member NoticeShown '' }
        return $cache
    }
    catch { return $empty }
}

# Writes text to a temporary file next to Path, then swaps it in, so readers never see half a file.
function Write-SLAtomicText {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
            else { [IO.File]::Move($temp, $Path) }
            return
        }
        catch {
            if ($attempt -eq 5) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
}

function Write-SLUpdateCache {
    param([Parameter(Mandatory)] $Cache)
    $dir = Get-SLCacheDirectory
    Write-SLAtomicText -Path (Join-Path $dir 'update-cache.json') -Text ($Cache | ConvertTo-Json -Depth 6)
    # The profile block reads only this: the earliest time any entry is due again.
    $next = [long]::MaxValue
    foreach ($p in $Cache.Entries.PSObject.Properties) { if ([long] $p.Value.NextCheckTicks -lt $next) { $next = [long] $p.Value.NextCheckTicks } }
    if ($next -eq [long]::MaxValue) { $next = 0 }
    Write-SLAtomicText -Path (Join-Path $dir 'next-check.txt') -Text "$next"
}

# Holds the lookup lock: a file opened exclusively, deleted when closed (also when the
# process ends). Returns the open stream, or $null if another process holds it.
function Enter-SLUpdateLock {
    $dir = Get-SLCacheDirectory
    if (-not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
    $file = Join-Path $dir 'update-cache.lock'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            return (New-Object IO.FileStream($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 16, [IO.FileOptions]::DeleteOnClose))
        }
        catch {
            $info = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
            $stale = $info -and ([DateTime]::UtcNow - $info.LastWriteTimeUtc).TotalMinutes -gt $script:SLLockStaleMinutes
            if (-not $stale -or $attempt -eq 2) { return $null }
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
}

function Get-SLCacheKey {
    param([string] $Name, [bool] $IncludePrerelease)
    $channel = 'stable'
    if ($IncludePrerelease) { $channel = 'prerelease' }
    return "PSGallery/$Name/$channel"
}

# ----------------------------------------------------------------- lookup --

# The newest version of Name on the PowerShell Gallery (v2 API), as a string.
# Bounded: TimeoutSeconds per request, 1 + Retries requests, 1 MB response.
function Get-SLGalleryVersion {
    param(
        [string] $Name = 'SecondLine',
        [int] $TimeoutSeconds = 3,
        [int] $Retries = 1,
        [switch] $IncludePrerelease
    )
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid module name '$Name'." }
    $filter = 'IsLatestVersion'
    if ($IncludePrerelease) { $filter = 'IsAbsoluteLatestVersion' }
    $uri = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='$Name'&`$filter=$filter"
    $lastError = $null
    for ($attempt = 0; $attempt -le $Retries; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Milliseconds 500 }
        try { return (Invoke-SLGalleryRequest -Uri $uri -TimeoutSeconds $TimeoutSeconds -IncludePrerelease:$IncludePrerelease) }
        catch { $lastError = $_.Exception.Message }
    }
    throw "Gallery lookup for $Name failed after $($Retries + 1) attempt(s): $lastError"
}

function Invoke-SLGalleryRequest {
    param([string] $Uri, [int] $TimeoutSeconds, [switch] $IncludePrerelease)
    $client = $null
    $response = $null
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $client.MaxResponseContentBufferSize = 1048576
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        [void] $response.EnsureSuccessStatusCode()
        $xmlText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return (Select-SLGalleryFeedVersion -Xml $xmlText -IncludePrerelease:$IncludePrerelease)
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

# The best version in a Gallery v2 feed: stable only unless -IncludePrerelease.
# DTDs and external entities are refused.
function Select-SLGalleryFeedVersion {
    param([Parameter(Mandatory)] [string] $Xml, [switch] $IncludePrerelease)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($Xml)), $settings)
    try {
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
    }
    finally { $reader.Dispose() }
    $versions = @(
        foreach ($node in $document.SelectNodes("//*[local-name()='properties']")) {
            $versionNode = $node.SelectSingleNode("*[local-name()='Version']")
            if (-not $versionNode) { continue }
            $text = $versionNode.InnerText.Trim()
            if ($null -eq (ConvertTo-SLVersionParts $text)) { continue }
            if (-not $IncludePrerelease -and (Test-SLPrerelease $text)) { continue }
            $text
        }
    )
    if ($versions.Count -eq 0) { throw 'The Gallery returned no usable version.' }
    if (-not $IncludePrerelease) { return (Select-SLBestVersion $versions) }
    # Prerelease channel: simply the newest, even if it is a prerelease.
    $best = $versions[0]
    foreach ($v in $versions) { if ((Compare-SLVersion $v $best) -gt 0) { $best = $v } }
    return $best
}

# The highest installed version of Name, from the module path. No import.
function Get-SLInstalledVersion {
    param([string] $Name = 'SecondLine')
    $best = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($best) { return "$($best.Version)" }
    return $null
}

# ------------------------------------------------------------------ status --

# Turns a cache entry into a status, without network access:
#   Lookup  Current | Stale | Failed | NotChecked | Disabled
#   Update  UpdateAvailable | UpToDate | Unknown
function Get-SLUpdateState {
    param(
        $Entry,
        [hashtable] $Options,
        [string] $Installed,
        [string] $Name = 'SecondLine'
    )
    $now = [DateTime]::UtcNow.Ticks
    $latest = $null
    $checked = $null
    $lookup = 'NotChecked'
    $errorText = $null
    if ($Entry) {
        if ($Entry.Latest) { $latest = "$($Entry.Latest)" }
        if ($Entry.CheckedTicks) { $checked = New-Object DateTime ([long] $Entry.CheckedTicks), ([DateTimeKind]::Utc) }
        $failedLater = $Entry.LastError -and [long] $Entry.AttemptTicks -gt [long] $Entry.CheckedTicks
        if ($failedLater) { $lookup = 'Failed'; $errorText = "$($Entry.LastError)" }
        elseif ($checked -and ($now - $checked.Ticks) -lt [TimeSpan]::FromHours($Options.RefreshHours).Ticks) { $lookup = 'Current' }
        elseif ($checked) { $lookup = 'Stale' }
    }
    if (-not $Options.Enabled -and $lookup -ne 'Current') { $lookup = 'Disabled' }

    $update = 'Unknown'
    if ($latest -and $Installed) {
        if ((Compare-SLVersion $latest $Installed) -gt 0) { $update = 'UpdateAvailable' } else { $update = 'UpToDate' }
    }
    $message = switch ($update) {
        'UpdateAvailable' { "$Name $latest available; installed $Installed." }
        'UpToDate' { "$Name $Installed is the newest stable release." }
        default {
            if ($latest) { "Newest stable $Name is $latest; no installed $Name found to compare." }
            else { "$Name update status unknown." }
        }
    }
    $nextDue = $null
    if ($Entry -and $Entry.NextCheckTicks) { $nextDue = New-Object DateTime ([long] $Entry.NextCheckTicks), ([DateTimeKind]::Utc) }
    return [pscustomobject]@{
        Name       = $Name
        Installed  = $Installed
        Latest     = $latest
        Update     = $update
        Lookup     = $lookup
        CheckedUtc = $checked
        NextDueUtc = $nextDue
        LastError  = $errorText
        Message    = $message
    }
}

# Age as '3 h ago', for one-line status.
function Format-SLAge {
    param($Utc)
    if (-not $Utc) { return 'never' }
    $span = [DateTime]::UtcNow - [DateTime] $Utc
    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalHours -lt 1) { return "$([int] $span.TotalMinutes) min ago" }
    if ($span.TotalDays -lt 2) { return "$([int] $span.TotalHours) h ago" }
    return "$([int] $span.TotalDays) days ago"
}

# ----------------------------------------------------------------- refresh --

# Refreshes the shared cache entry for Name when it is due (or -Force), under the lock.
# Returns the state, plus Ran (a request was made), Busy (another process holds the
# lock) and Notice (an actionable line not yet shown, else $null).
#   -NoticeFile  also leave the notice in notice.txt, for the next interactive shell
function Update-SLUpdateCache {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private. It writes only the SecondLine cache; Invoke-SLUpdateCheck and Show-SLHelp document that.')]
    param(
        [string] $Name = 'SecondLine',
        [hashtable] $Options,
        [switch] $Force,
        [switch] $NoticeFile
    )
    if (-not $Options) { $Options = ConvertTo-SLUpdateOptions (Get-SLUpdateSettings) }
    $key = Get-SLCacheKey -Name $Name -IncludePrerelease ([bool] $Options.IncludePrerelease)
    $ran = $false
    $busy = $false
    $notice = $null

    # Without the lock, only read: another process is writing the cache right now.
    $lock = Enter-SLUpdateLock
    $busy = $null -eq $lock
    try {
        # Read inside the lock: another process may have just finished this lookup.
        $cache = Read-SLUpdateCache
        $entry = $null
        if ($cache.Entries.PSObject.Properties[$key]) { $entry = $cache.Entries.$key }
        $now = [DateTime]::UtcNow
        $due = -not $entry -or [long] $entry.NextCheckTicks -le $now.Ticks
        if ($lock -and ($Force -or ($due -and $Options.Enabled))) {
            if (-not $entry) {
                $entry = [pscustomobject]@{ Latest = $null; CheckedTicks = 0; AttemptTicks = 0; LastError = $null; NextCheckTicks = 0 }
                $cache.Entries | Add-Member -NotePropertyName $key -NotePropertyValue $entry
            }
            $ran = $true
            $entry.AttemptTicks = $now.Ticks
            try {
                $entry.Latest = Get-SLGalleryVersion -Name $Name -TimeoutSeconds $Options.TimeoutSeconds -Retries $Options.Retries -IncludePrerelease:$Options.IncludePrerelease
                $entry.CheckedTicks = [DateTime]::UtcNow.Ticks
                $entry.LastError = $null
                $entry.NextCheckTicks = $now.AddHours($Options.RefreshHours).Ticks
            }
            catch {
                $entry.LastError = $_.Exception.Message
                $entry.NextCheckTicks = $now.AddMinutes($Options.FailureBackoffMinutes).Ticks
            }
        }
        elseif (-not $Options.Enabled -and -not $Force) {
            # Disabled: push the profile block's next look out, so it doesn't start a process every shell.
            if (-not $entry) {
                $entry = [pscustomobject]@{ Latest = $null; CheckedTicks = 0; AttemptTicks = 0; LastError = $null; NextCheckTicks = 0 }
                $cache.Entries | Add-Member -NotePropertyName $key -NotePropertyValue $entry
            }
            $entry.NextCheckTicks = $now.AddHours($Options.RefreshHours).Ticks
        }

        $state = Get-SLUpdateState -Entry $entry -Options $Options -Installed (Get-SLInstalledVersion -Name $Name) -Name $Name
        $noticeKey = "$Name|$($state.Latest)|$($state.Installed)"
        if ($state.Update -eq 'UpdateAvailable' -and $cache.NoticeShown -ne $noticeKey) {
            $notice = $state.Message
            if ($lock) { $cache.NoticeShown = $noticeKey }
        }
        if ($lock) {
            Write-SLUpdateCache -Cache $cache
            if ($NoticeFile -and $notice) { Write-SLAtomicText -Path (Join-Path (Get-SLCacheDirectory) 'notice.txt') -Text $notice }
        }
    }
    finally { if ($lock) { $lock.Dispose() } }
    $state | Add-Member -NotePropertyName Ran -NotePropertyValue $ran
    $state | Add-Member -NotePropertyName Busy -NotePropertyValue $busy
    $state | Add-Member -NotePropertyName Notice -NotePropertyValue $notice
    return $state
}

# The cached state for Name. Reads local files only: never the network.
function Get-SLCachedUpdateState {
    param([string] $Name = 'SecondLine', [hashtable] $Options)
    if (-not $Options) { $Options = ConvertTo-SLUpdateOptions (Get-SLUpdateSettings) }
    $cache = Read-SLUpdateCache
    $key = Get-SLCacheKey -Name $Name -IncludePrerelease ([bool] $Options.IncludePrerelease)
    $entry = $null
    if ($cache.Entries.PSObject.Properties[$key]) { $entry = $cache.Entries.$key }
    return (Get-SLUpdateState -Entry $entry -Options $Options -Installed (Get-SLInstalledVersion -Name $Name) -Name $Name)
}

# -------------------------------------------------------------- background --

# Starts one background refresh for this session, unless one is running, the cache is
# current (without -Force), checks are disabled, or a failed start is backing off.
# Returns Started | InFlight | NotNeeded | Disabled | Unavailable. Never waits on the network.
# When the job ends, an event action prints the notice (if any) and removes the job
# and its subscription.
function Start-SLBackgroundUpdateCheck {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private. It starts a session job for the opt-out help check (-NoUpdateCheck); confirming each time would defeat background help.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'The job script block declares parameters; every value comes from -ArgumentList.')]
    param([hashtable] $Options, $State, [string] $Directory, [switch] $Force)
    $session = Get-Variable -Name SLUpdateJobState -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if (-not $session) {
        $session = @{ Job = $null; RetryUtc = [DateTime]::MinValue; Result = $null }
        $script:SLUpdateJobState = $session
    }
    if ($session.Job) { return 'InFlight' }
    if (-not $Options.Enabled) { return 'Disabled' }
    if (-not $Force -and $State -and $State.Lookup -eq 'Current') { return 'NotNeeded' }
    # A failed lookup has a shared backoff; don't start a process just to find that out.
    if (-not $Force -and $State -and $State.Lookup -eq 'Failed' -and $State.NextDueUtc -and $State.NextDueUtc -gt [DateTime]::UtcNow) { return 'NotNeeded' }
    if ([DateTime]::UtcNow -lt $session.RetryUtc) { return 'Unavailable' }
    try {
        $manifest = Join-Path $ExecutionContext.SessionState.Module.ModuleBase 'SecondLine.psd1'
        if (-not $Directory) { $Directory = (Get-Location).ProviderPath }
        $session.Job = Start-Job -ScriptBlock {
            param($Manifest, $Directory, $Force)
            $ErrorActionPreference = 'Stop'
            Set-Location -LiteralPath $Directory
            Import-Module $Manifest -Force
            SecondLine\Invoke-SLUpdateCheck -Force:$Force -Quiet -PassThru
        } -ArgumentList $manifest, $Directory, ([bool] $Force) -ErrorAction Stop
        $sourceId = 'SecondLine.UpdateCheck.' + [guid]::NewGuid().ToString('N')
        Register-ObjectEvent -InputObject $session.Job -EventName StateChanged -SourceIdentifier $sourceId -MessageData $session -Action {
            $shared = $event.MessageData
            $job = $shared.Job
            if ($job -and $job.State -in @('Completed', 'Failed', 'Stopped')) {
                try {
                    $result = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) | Select-Object -Last 1
                    $shared.Result = $result
                    if ($job.State -eq 'Completed' -and $result -and $result.Notice) {
                        Write-Host $result.Notice -ForegroundColor Yellow
                    }
                    elseif ($job.State -ne 'Completed') { $shared.RetryUtc = [DateTime]::UtcNow.AddMinutes(5) }
                }
                finally {
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                    $shared.Job = $null
                    Unregister-Event -SourceIdentifier $eventSubscriber.SourceIdentifier -ErrorAction SilentlyContinue
                    if ($eventSubscriber.Action) { Remove-Job -Job $eventSubscriber.Action -Force -ErrorAction SilentlyContinue }
                }
            }
        } -ErrorAction Stop | Out-Null
        # The job may have finished before the subscription existed.
        if ($session.Job -and $session.Job.State -in @('Completed', 'Failed', 'Stopped')) {
            New-Event -SourceIdentifier $sourceId -MessageData $session | Out-Null
        }
        return 'Started'
    }
    catch {
        if ($session.Job) { Remove-Job -Job $session.Job -Force -ErrorAction SilentlyContinue }
        $session.Job = $null
        $session.RetryUtc = [DateTime]::UtcNow.AddMinutes(5)
        return 'Unavailable'
    }
}

# ------------------------------------------------------------- profile block --

$script:SLProfileStart = '# >>> SecondLine update check >>>'
$script:SLProfileEnd = '# <<< SecondLine update check <<<'

# The profile block's lines. It imports nothing into the shell, so a project's
# bootstrap can still choose its approved SecondLine version later in the session.
# It reads two small files; when a check is due it starts one hidden, no-profile
# PowerShell process that runs the shared check and exits.
function Get-SLProfileBlock {
    return @(
        $script:SLProfileStart
        '# Added by Enable-SLProfileUpdateCheck. Remove with Disable-SLProfileUpdateCheck, or delete through the end marker.'
        '# Shows a pending SecondLine update notice and, at most daily, starts a background check. Installs nothing.'
        'if ([Environment]::UserInteractive -and $env:SECONDLINE_NO_UPDATE_CHECK -ne ''1'' -and -not ([Environment]::GetCommandLineArgs() -match ''^-NonI'')) {'
        '    try {'
        '        $slDir = $env:SECONDLINE_CACHE_DIR'
        '        if (-not $slDir) { $slDir = Join-Path ([Environment]::GetFolderPath(''LocalApplicationData'')) ''SecondLine'' }'
        '        $slNotice = Join-Path $slDir ''notice.txt'''
        '        if (Test-Path -LiteralPath $slNotice) { Write-Host ([IO.File]::ReadAllText($slNotice).Trim()) -ForegroundColor Yellow; Remove-Item -LiteralPath $slNotice -ErrorAction SilentlyContinue }'
        '        $slNext = Join-Path $slDir ''next-check.txt'''
        '        $slDue = 0L'
        '        if (Test-Path -LiteralPath $slNext) { [void] [long]::TryParse([IO.File]::ReadAllText($slNext).Trim(), [ref] $slDue) }'
        '        if ($slDue -le [DateTime]::UtcNow.Ticks) {'
        '            Start-Process -FilePath (Get-Process -Id $PID).Path -WindowStyle Hidden -ArgumentList ''-NoProfile'', ''-NonInteractive'', ''-Command'', ''Import-Module SecondLine -MinimumVersion 0.4.0; SecondLine\Invoke-SLUpdateCheck -NoticeFile -Quiet'''
        '        }'
        '    }'
        '    catch { }'
        '    Remove-Variable slDir, slNotice, slNext, slDue -ErrorAction SilentlyContinue'
        '}'
        $script:SLProfileEnd
    )
}

# Each marked block in Text: Start, BlockLength (markers included) and Length (with
# the line ending after it). A start marker without an end marker is an error.
function Find-SLProfileBlock {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $blocks = @()
    $pattern = '(?m)^' + [regex]::Escape($script:SLProfileStart) + '[^\r\n]*'
    $index = 0
    while ($true) {
        $m = [regex]::Match($Text.Substring($index), $pattern)
        if (-not $m.Success) { break }
        $start = $index + $m.Index
        $end = $Text.IndexOf($script:SLProfileEnd, $start, [StringComparison]::Ordinal)
        if ($end -lt 0) { throw "The SecondLine profile block that starts at character $start has no end marker '$($script:SLProfileEnd)'. Nothing was changed; fix the block by hand." }
        $blockLength = $end + $script:SLProfileEnd.Length - $start
        $length = $blockLength
        if ($Text.Length -gt $start + $length -and $Text[$start + $length] -eq "`r") { $length++ }
        if ($Text.Length -gt $start + $length -and $Text[$start + $length] -eq "`n") { $length++ }
        $blocks += [pscustomobject]@{ Start = $start; BlockLength = $blockLength; Length = $length }
        $index = $start + $length
    }
    return , $blocks
}

# ------------------------------------------------------------- reporting --

# One concise line for a state: actionable first, then how fresh the answer is.
function Format-SLUpdateLine {
    param([Parameter(Mandatory)] $State, [string] $DisabledBy)
    $age = Format-SLAge $State.CheckedUtc
    $line = switch ($State.Lookup) {
        'Current' { "$($State.Message) (checked $age)" }
        'Stale' { "$($State.Message) Last Gallery check $age; refresh due." }
        'Failed' {
            $when = ''
            if ($State.NextDueUtc) { $when = " Next attempt after $($State.NextDueUtc.ToLocalTime().ToString('HH:mm'))." }
            "Gallery lookup failed (offline?); update status unknown, not up to date. Last success: $age.$when"
        }
        'Disabled' { "Update checks are off ($DisabledBy). Last Gallery check: $age." }
        default { 'Not checked yet. Run Invoke-SLUpdateCheck, or open Show-SLHelp to check in the background.' }
    }
    if ($State.Lookup -eq 'Failed' -and $State.Update -eq 'UpdateAvailable') { $line = "$($State.Message) $line" }
    if ($State.PSObject.Properties['Busy'] -and $State.Busy) { $line = "Another session is checking right now; cached result: $line" }
    return $line
}

# Update availability, version policy and advisories for SecondLine, from local
# files only. The three categories stay separate:
#   Update    UpdateAvailable | UpToDate | Unknown (newest Gallery release vs highest installed)
#   Policy    Match | Mismatch | NotInstalled | NotPinned | Invalid (the loaded version vs the project's ModuleVersions)
#   Advisory  NotConfigured: SecondLine has no security-advisory source and reports none
function Get-SLDependencyHealth {
    param([Parameter(Mandatory)] $State, [string] $Standard, [string] $Directory, [string] $Loaded)
    if (-not $Loaded) { $Loaded = "$($ExecutionContext.SessionState.Module.Version)" }
    $approved = $null
    $approvedSource = $null
    $policy = 'NotPinned'
    $policyNote = 'No ModuleVersions.SecondLine in the project or settings.'
    try {
        $versions = Resolve-SLModuleVersionPolicy -Standard $Standard -Directory $Directory -DevelopmentPath $script:SLDevelopmentStandard
        if ($versions.ContainsKey('SecondLine')) {
            $approved = "$($versions['SecondLine'].Value)"
            $approvedSource = $versions['SecondLine'].Source
            if ((Compare-SLVersion $approved $Loaded) -eq 0) { $policy = 'Match'; $policyNote = "Loaded $Loaded is approved by $approvedSource." }
            else {
                $policy = 'Mismatch'
                $policyNote = "Version-policy mismatch: loaded $Loaded; $approvedSource approves $approved."
                $have = @(Get-Module -ListAvailable -Name SecondLine -ErrorAction SilentlyContinue | Where-Object { "$($_.Version)" -eq $approved })
                if ($have.Count -eq 0) { $policy = 'NotInstalled'; $policyNote = "SecondLine $approved is approved by $approvedSource but not installed; loaded $Loaded." }
            }
        }
    }
    catch { $policy = 'Invalid'; $policyNote = "Version policy could not be read: $($_.Exception.Message)" }

    $notices = @()
    if ($State.Update -eq 'UpdateAvailable') { $notices += $State.Message }
    if ($policy -in 'Mismatch', 'NotInstalled', 'Invalid') { $notices += $policyNote }
    return [pscustomobject]@{
        PSTypeName     = 'SecondLine.DependencyHealth'
        Name           = 'SecondLine'
        Loaded         = $Loaded
        Installed      = $State.Installed
        Latest         = $State.Latest
        Update         = $State.Update
        Lookup         = $State.Lookup
        CheckedUtc     = $State.CheckedUtc
        LastError      = $State.LastError
        Approved       = $approved
        ApprovedSource = $approvedSource
        Policy         = $policy
        PolicyNote     = $policyNote
        Advisory       = 'NotConfigured'
        AdvisoryNote   = 'No security-advisory source is configured; SecondLine reports no advisories rather than guess.'
        Notices        = $notices
    }
}
