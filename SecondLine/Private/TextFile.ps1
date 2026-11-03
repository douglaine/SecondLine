# Byte-preserving text edits for files SecondLine changes but doesn't own: profiles,
# .editorconfig, VS Code settings and line-ending repairs.
#
# ASCII-compatible files (UTF-8, ANSI code pages) are handled as Latin-1, which maps
# each byte to one char and back. An edit that only touches ASCII therefore leaves
# every other byte, including multi-byte UTF-8 and the BOM, exactly as it was.
# UTF-16 files (with a BOM) are decoded and re-encoded with the same encoding.

$script:SLLatin1 = [Text.Encoding]::GetEncoding(28591)

# Reads a file as Text (string) plus what's needed to write it back unchanged:
# Kind (Bytes | Utf16LE | Utf16BE), Preamble (BOM bytes) and Newline (dominant ending).
function Read-SLTextFile {
    param([Parameter(Mandatory)] [string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $kind = 'Bytes'
    $preamble = [byte[]] @()
    $body = $bytes
    if ($bytes.Length -ge 4 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) -or ($bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF))) {
        throw "$Path is UTF-32, which SecondLine does not edit."
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $preamble = [byte[]] $bytes[0..2] }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $kind = 'Utf16LE'; $preamble = [byte[]] $bytes[0..1] }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $kind = 'Utf16BE'; $preamble = [byte[]] $bytes[0..1] }
    if ($preamble.Length -gt 0) {
        $body = New-Object byte[] ($bytes.Length - $preamble.Length)
        [Array]::Copy($bytes, $preamble.Length, $body, 0, $body.Length)
    }
    $text = (Get-SLTextEncoding $kind).GetString($body)
    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $lf = ([regex]::Matches($text, "(?<!`r)`n")).Count
    $newline = "`r`n"
    if ($lf -gt $crlf) { $newline = "`n" }
    return [pscustomobject]@{ Path = $Path; Text = $text; Kind = $kind; Preamble = $preamble; Newline = $newline; Crlf = $crlf; Lf = $lf }
}

function Get-SLTextEncoding {
    param([string] $Kind)
    switch ($Kind) {
        'Utf16LE' { return (New-Object Text.UnicodeEncoding($false, $false)) }
        'Utf16BE' { return (New-Object Text.UnicodeEncoding($true, $false)) }
        default { return $script:SLLatin1 }
    }
}

# Writes Text back with the original encoding and BOM, through a temporary file.
function Write-SLTextFile {
    param([Parameter(Mandatory)] $File, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [string] $Path)
    if (-not $Path) { $Path = $File.Path }
    $body = (Get-SLTextEncoding $File.Kind).GetBytes($Text)
    $bytes = New-Object byte[] ($File.Preamble.Length + $body.Length)
    [Array]::Copy([byte[]] $File.Preamble, 0, $bytes, 0, $File.Preamble.Length)
    [Array]::Copy($body, 0, $bytes, $File.Preamble.Length, $body.Length)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllBytes($temp, $bytes)
    try {
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    }
    catch { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw }
}

# A new, empty file description: UTF-8 without BOM, with the platform's line ending.
function New-SLTextFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Describes a file to create; writes nothing.')]
    param([Parameter(Mandatory)] [string] $Path)
    $newline = "`r`n"
    if ([IO.Path]::DirectorySeparatorChar -eq '/') { $newline = "`n" }
    return [pscustomobject]@{ Path = $Path; Text = ''; Kind = 'Bytes'; Preamble = [byte[]] @(); Newline = $newline; Crlf = 0; Lf = 0 }
}
