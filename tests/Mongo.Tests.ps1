#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# InModuleScope at Describe level runs during discovery, before BeforeAll.
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
}

BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force

    # Writes a .mlaunch_startup like mlaunch does (Windows-style mixed separators
    # in the recorded paths) and optionally creates the node data folders.
    function New-FakeSet {
        param([string] $Root, [int] $BasePort = 47017, [switch] $CreateNodes, [string] $Name = 'replset')
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        $info = [ordered]@{}
        for ($i = 1; $i -le 3; $i++) {
            $db  = Join-Path $Root "$Name/rs$i/db"
            $log = Join-Path $Root "$Name/rs$i/mongod.log"
            if ($CreateNodes) { New-Item -ItemType Directory -Force -Path $db | Out-Null }
            $info["$($BasePort + $i - 1)"] = "start /b `"`" `"mongod.exe`" --replSet $Name --dbpath `"$db`"  --logpath `"$log`" --port $($BasePort + $i - 1)"
        }
        $json = [ordered]@{
            protocol_version = 2
            mtools_version   = '1.7.2'
            parsed_args      = [ordered]@{ replicaset = $true; sharded = $null; nodes = 3; name = $Name; port = $BasePort; hostname = 'localhost'; dir = $Root }
            startup_info     = $info
        }
        $json | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root '.mlaunch_startup') -Encoding UTF8
    }
}

Describe 'Find-SLMongoReplicaSet' {
    It 'reads name, ports and node data folders' {
        New-FakeSet -Root (Join-Path $TestDrive 'a') -CreateNodes
        $set = Find-SLMongoReplicaSet -Path (Join-Path $TestDrive 'a')
        $set.Name  | Should -Be 'replset'
        $set.Ports -join ',' | Should -Be '47017,47018,47019'
        $set.Valid | Should -BeTrue
        $set.Nodes.Count | Should -Be 3
    }

    It 'flags a stale startup file whose node folders do not exist' {
        New-FakeSet -Root (Join-Path $TestDrive 'stale')
        $set = Find-SLMongoReplicaSet -Path (Join-Path $TestDrive 'stale')
        $set.Valid   | Should -BeFalse
        $set.Problem | Should -Match 'missing'
    }

    It 'finds nested sets and reports each' {
        $root = Join-Path $TestDrive 'nested'
        New-FakeSet -Root $root
        New-FakeSet -Root (Join-Path $root 'replset') -CreateNodes
        $all = @(Find-SLMongoReplicaSet -Path $root)
        $all.Count | Should -Be 2
        @($all | Where-Object Valid).Count | Should -Be 1
    }

    It 'flags a copied startup file (e.g. in a backup folder) instead of treating it as a second set' {
        $root = Join-Path $TestDrive 'withbackup'
        New-FakeSet -Root (Join-Path $root 'data') -CreateNodes
        $bak = Join-Path $root 'backup stuff'
        New-Item -ItemType Directory -Force -Path $bak | Out-Null
        Copy-Item (Join-Path $root 'data/.mlaunch_startup') $bak
        $all = @(Find-SLMongoReplicaSet -Path $root)
        $all.Count | Should -Be 2
        $valid = @($all | Where-Object Valid)
        $valid.Count | Should -Be 1
        $valid[0].Dir | Should -Be (Join-Path $root 'data')
        ($all | Where-Object { -not $_.Valid }).Problem | Should -Match 'copy of the startup file'
    }

    It 'rejects a file that is not JSON' {
        $d = Join-Path $TestDrive 'junk'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d '.mlaunch_startup') -Value 'not json'
        (Find-SLMongoReplicaSet -Path $d).Problem | Should -Match 'JSON'
    }

    It 'rejects a non-replica-set startup file' {
        $d = Join-Path $TestDrive 'single'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        '{ "parsed_args": { "replicaset": false, "single": true, "port": 27017 } }' |
            Set-Content -LiteralPath (Join-Path $d '.mlaunch_startup')
        (Find-SLMongoReplicaSet -Path $d).Problem | Should -Match 'not a replica set'
    }
}

Describe 'Path handling' {
    InModuleScope SecondLine {
        It 'normalizes the mixed separators mlaunch records' {
            $sep = [IO.Path]::DirectorySeparatorChar
            ConvertTo-SLLocalPath 'C:\data\replset/rs1\db' | Should -Be ("C:{0}data{0}replset{0}rs1{0}db" -f $sep)
        }
    }
}

Describe 'Port checks' {
    InModuleScope SecondLine {
        It 'sees an open port and a closed one' {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            try {
                $port = $listener.LocalEndpoint.Port
                Test-SLPortOpen -Port $port | Should -BeTrue
                $listener.Stop()
                Test-SLPortOpen -Port $port | Should -BeFalse
            }
            finally { $listener.Stop() }
        }
    }
}

Describe 'Resolving which set to use' {
    BeforeEach {
        $script:oldDir  = $env:SECONDLINE_MONGO_DIR
        $script:oldRoot = $env:SECONDLINE_MONGO_ROOT
        $env:SECONDLINE_MONGO_DIR = $null
    }
    AfterEach {
        $env:SECONDLINE_MONGO_DIR  = $script:oldDir
        $env:SECONDLINE_MONGO_ROOT = $script:oldRoot
    }

    It 'uses the one valid set and ignores a stale one' {
        $root = Join-Path $TestDrive 'r1'
        New-FakeSet -Root (Join-Path $root 'old')
        New-FakeSet -Root (Join-Path $root 'live') -CreateNodes -BasePort 47117
        $env:SECONDLINE_MONGO_ROOT = $root
        $s = Get-SLMongoStatus -Quiet
        $s.Dir    | Should -Be (Join-Path $root 'live')
        $s.Status | Should -Be 'DOWN'
    }

    It 'asks for -Path when two sets are valid' {
        $root = Join-Path $TestDrive 'r2'
        New-FakeSet -Root (Join-Path $root 'one') -CreateNodes -BasePort 47217
        New-FakeSet -Root (Join-Path $root 'two') -CreateNodes -BasePort 47317
        $env:SECONDLINE_MONGO_ROOT = $root
        { Get-SLMongoStatus -Quiet } | Should -Throw '*more than one usable*'
        (Get-SLMongoStatus -Path (Join-Path $root 'two') -Quiet).Dir | Should -Be (Join-Path $root 'two')
    }

    It 'explains when nothing is found' {
        $env:SECONDLINE_MONGO_ROOT = Join-Path $TestDrive 'empty-root'
        { Get-SLMongoStatus -Quiet } | Should -Throw '*No .mlaunch_startup found*'
    }

    It 'explains why an explicit -Path cannot be used' {
        $d = Join-Path $TestDrive 'r3'
        New-FakeSet -Root $d
        { Get-SLMongoStatus -Path $d -Quiet } | Should -Throw '*missing*'
    }

    It 'honours SECONDLINE_MONGO_DIR' {
        $d = Join-Path $TestDrive 'r4'
        New-FakeSet -Root $d -CreateNodes -BasePort 47417
        $env:SECONDLINE_MONGO_DIR = $d
        (Get-SLMongoStatus -Quiet).Dir | Should -Be $d
    }

    It 'Stop-SLMongo on a stopped set does nothing' {
        $d = Join-Path $TestDrive 'r5'
        New-FakeSet -Root $d -CreateNodes -BasePort 47517
        (Stop-SLMongo -Path $d -Quiet).Method | Should -Be 'already stopped'
    }
}
