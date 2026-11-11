# Pester 5 tests for the helper functions in install.ps1. The functions are loaded from the
# script's syntax tree, so install.ps1 itself never runs and every file they touch is in TestDrive.

BeforeAll {
    Set-StrictMode -Version Latest
    $installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$null)
    foreach ($definition in $tree.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    # Stands in for the script's $PSCmdlet: ShouldProcess answers with $script:allowChanges.
    $script:cmdlet = [pscustomobject]@{}
    $script:cmdlet | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { $script:allowChanges }

    # The 24 bytes Get-PngSize reads: signature, IHDR chunk header, big-endian width and height.
    function Write-TestPng {
        param([string]$Path, [int]$Width, [int]$Height)
        $bytes = [System.Collections.Generic.List[byte]]::new()
        $bytes.AddRange([byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52))
        foreach ($value in $Width, $Height) {
            foreach ($shift in 24, 16, 8, 0) { $bytes.Add([byte](($value -shr $shift) -band 0xFF)) }
        }
        [System.IO.File]::WriteAllBytes($Path, $bytes.ToArray())
    }
}

Describe 'install.ps1 helpers' {
    BeforeAll {
        $script:canLink = Test-SymlinkSupport -Directory $TestDrive
    }

    BeforeEach {
        $script:allowChanges = $true
        $script:changes = [System.Collections.Generic.List[string]]::new()
        $script:useCopy = $true
        $script:work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work | Out-Null
        $script:backupDir = Join-Path $script:work 'backup'
    }

    Context 'Get-PngSize' {
        It 'reads a width and height above 255 from the header' {
            $png = Join-Path $script:work 'wide.png'
            Write-TestPng -Path $png -Width 3440 -Height 1440
            $size = Get-PngSize -Path $png
            $size.Width | Should -Be 3440
            $size.Height | Should -Be 1440
        }

        It 'returns nothing for a file that is not a PNG' {
            $file = Join-Path $script:work 'text.png'
            Set-Content -LiteralPath $file -Value 'plain text, long enough to fill a header'
            Get-PngSize -Path $file | Should -BeNullOrEmpty
        }
    }

    Context 'Get-FileHashSafe and Test-SameContent' {
        It 'hashes like Get-FileHash, in upper-case hex' {
            $file = Join-Path $script:work 'a.txt'
            Set-Content -LiteralPath $file -Value 'same'
            Get-FileHashSafe -Path $file | Should -BeExactly (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        }

        It 'returns nothing for a missing file' {
            Get-FileHashSafe -Path (Join-Path $script:work 'missing.txt') | Should -BeNullOrEmpty
        }

        It 'compares content, and a missing file never matches' {
            $one = Join-Path $script:work 'one.txt'
            $same = Join-Path $script:work 'same.txt'
            $other = Join-Path $script:work 'other.txt'
            Set-Content -LiteralPath $one -Value 'one'
            Set-Content -LiteralPath $same -Value 'one'
            Set-Content -LiteralPath $other -Value 'two'
            Test-SameContent -PathA $one -PathB $same | Should -BeTrue
            Test-SameContent -PathA $one -PathB $other | Should -BeFalse
            Test-SameContent -PathA $one -PathB (Join-Path $script:work 'missing.txt') | Should -BeFalse
        }
    }

    Context 'Test-LinkApplicable' {
        It 'applies an Always link unconditionally' {
            Test-LinkApplicable -Link @{ When = 'Always'; Destination = (Join-Path $script:work 'no\such\file') } | Should -BeTrue
        }

        It 'applies a ParentExists link only when the folder exists' {
            Test-LinkApplicable -Link @{ When = 'ParentExists'; Destination = (Join-Path $script:work 'settings.json') } | Should -BeTrue
            Test-LinkApplicable -Link @{ When = 'ParentExists'; Destination = (Join-Path $script:work 'absent\settings.json') } | Should -BeFalse
        }

        It 'applies a FileExists link only when the file exists' {
            $file = Join-Path $script:work 'settings.json'
            Test-LinkApplicable -Link @{ When = 'FileExists'; Destination = $file } | Should -BeFalse
            Set-Content -LiteralPath $file -Value '{}'
            Test-LinkApplicable -Link @{ When = 'FileExists'; Destination = $file } | Should -BeTrue
        }
    }

    Context 'Get-LinkState' {
        BeforeEach {
            $script:source = Join-Path $script:work 'source.json'
            $script:destination = Join-Path $script:work 'destination.json'
            Set-Content -LiteralPath $script:source -Value '{ "a": 1 }'
        }

        It 'tells missing, copied and real-file apart' {
            (Get-LinkState -Source $script:source -Destination $script:destination).State | Should -Be 'missing'
            Copy-Item -LiteralPath $script:source -Destination $script:destination
            (Get-LinkState -Source $script:source -Destination $script:destination).State | Should -Be 'copied'
            Set-Content -LiteralPath $script:destination -Value '{ "a": 2 }'
            (Get-LinkState -Source $script:source -Destination $script:destination).State | Should -Be 'real-file'
        }

        It 'tells a link to the source from a link elsewhere' {
            if (-not $script:canLink) {
                Set-ItResult -Skipped -Because 'this shell cannot create symlinks'
                return
            }
            New-Item -ItemType SymbolicLink -Path $script:destination -Target $script:source | Out-Null
            (Get-LinkState -Source $script:source -Destination $script:destination).State | Should -Be 'linked'
            Remove-Item -LiteralPath $script:destination
            $elsewhere = Join-Path $script:work 'elsewhere.json'
            Set-Content -LiteralPath $elsewhere -Value '{}'
            New-Item -ItemType SymbolicLink -Path $script:destination -Target $elsewhere | Out-Null
            (Get-LinkState -Source $script:source -Destination $script:destination).State | Should -Be 'stale-link'
        }
    }

    Context 'Install-Link' {
        BeforeEach {
            $script:source = Join-Path $script:work 'source.json'
            $script:destination = Join-Path $script:work 'app\settings.json'
            Set-Content -LiteralPath $script:source -Value 'new'
        }

        It 'copies into a missing folder and logs the change' {
            Install-Link -Source $script:source -Destination $script:destination
            Test-SameContent -PathA $script:source -PathB $script:destination | Should -BeTrue
            @($script:changes -like 'Copy from *').Count | Should -Be 1
            @(Get-Content -LiteralPath (Join-Path $script:backupDir 'changes.txt')) -like 'Copy from *' | Should -Not -BeNullOrEmpty
        }

        It 'moves a different file to the backup folder before copying' {
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:destination) | Out-Null
            Set-Content -LiteralPath $script:destination -Value 'old'
            Install-Link -Source $script:source -Destination $script:destination
            Get-Content -LiteralPath $script:destination | Should -Be 'new'
            Get-Content -LiteralPath (Join-Path $script:backupDir 'settings.json') | Should -Be 'old'
        }

        It 'leaves an identical copy alone and writes nothing' {
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:destination) | Out-Null
            Copy-Item -LiteralPath $script:source -Destination $script:destination
            Install-Link -Source $script:source -Destination $script:destination
            $script:changes.Count | Should -Be 0
            Test-Path -LiteralPath $script:backupDir | Should -BeFalse
        }

        It 'puts the original back when the symlink cannot be made' {
            $script:useCopy = $false
            Mock New-Item { throw 'symlinks are not allowed here' } -ParameterFilter { $ItemType -eq 'SymbolicLink' }
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:destination) | Out-Null
            Set-Content -LiteralPath $script:destination -Value 'old'
            { Install-Link -Source $script:source -Destination $script:destination } | Should -Throw '*Could not create a symlink*'
            Get-Content -LiteralPath $script:destination | Should -Be 'old'
            Test-Path -LiteralPath (Join-Path $script:backupDir 'settings.json') | Should -BeFalse
        }

        It 'backs up a real file and links it when symlinks work' {
            if (-not $script:canLink) {
                Set-ItResult -Skipped -Because 'this shell cannot create symlinks'
                return
            }
            $script:useCopy = $false
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:destination) | Out-Null
            Set-Content -LiteralPath $script:destination -Value 'old'
            Install-Link -Source $script:source -Destination $script:destination
            (Get-LinkState -Source $script:source -Destination $script:destination).State | Should -Be 'linked'
            Get-Content -LiteralPath (Join-Path $script:backupDir 'settings.json') | Should -Be 'old'
        }
    }

    Context 'Backup-Item' {
        It 'keeps an earlier backup that has the same name' {
            New-Item -ItemType Directory -Path $script:backupDir | Out-Null
            Set-Content -LiteralPath (Join-Path $script:backupDir 'settings.json') -Value 'first'
            $file = Join-Path $script:work 'settings.json'
            Set-Content -LiteralPath $file -Value 'second'
            $moved = Backup-Item -Path $file
            Split-Path -Leaf $moved | Should -Be 'settings.1.json'
            Get-Content -LiteralPath $moved | Should -Be 'second'
            Get-Content -LiteralPath (Join-Path $script:backupDir 'settings.json') | Should -Be 'first'
        }
    }

    Context 'Invoke-Change' {
        It 'runs the change and logs it when ShouldProcess agrees' {
            $marker = Join-Path $script:work 'ran.txt'
            Invoke-Change -Target 'target' -Action 'Write marker' -Do { Set-Content -LiteralPath $marker -Value 'x' } | Should -BeTrue
            Test-Path -LiteralPath $marker | Should -BeTrue
            $script:changes | Should -Be @('Write marker -> target')
            Get-Content -LiteralPath (Join-Path $script:backupDir 'changes.txt') | Should -Be 'Write marker -> target'
        }

        It 'changes and writes nothing when ShouldProcess declines, as under -WhatIf' {
            $script:allowChanges = $false
            $marker = Join-Path $script:work 'ran.txt'
            Invoke-Change -Target 'target' -Action 'Write marker' -Do { Set-Content -LiteralPath $marker -Value 'x' } | Should -BeFalse
            Test-Path -LiteralPath $marker | Should -BeFalse
            $script:changes.Count | Should -Be 0
            Test-Path -LiteralPath $script:backupDir | Should -BeFalse
        }

        It 'keeps the cmdlets inside a confirmed change from asking again' {
            $ConfirmPreference = 'Low'
            $script:seen = $null
            Invoke-Change -Target 'target' -Action 'Look' -Do { $script:seen = $ConfirmPreference } | Out-Null
            $script:seen | Should -Be 'None'
        }
    }

    Context 'Get-PackageId' {
        It 'lists the IDs from every source of a winget export' {
            $file = Join-Path $script:work 'packages.json'
            Set-Content -LiteralPath $file -Value '{ "Sources": [ { "Packages": [ { "PackageIdentifier": "A.One" }, { "PackageIdentifier": "B.Two" } ] }, { "Packages": [ { "PackageIdentifier": "C.Three" } ] } ] }'
            Get-PackageId -Files $file | Should -Be @('A.One', 'B.Two', 'C.Three')
        }

        It 'reads the tool set in winget\packages.json' {
            Get-PackageId -Files (Join-Path (Split-Path -Parent $PSScriptRoot) 'winget\packages.json') | Should -Contain 'Microsoft.WindowsTerminal'
        }
    }

    Context 'Get-RenderMarker' {
        BeforeEach {
            $script:wallDir = $script:work
            $script:marker = Join-Path $script:work 'render.json'
        }

        It 'returns a marker that names the generator and the size' {
            Set-Content -LiteralPath $script:marker -Value '{ "Generator": "ABC", "Width": 2560, "Height": 1440 }'
            (Get-RenderMarker).Width | Should -Be 2560
        }

        It 'returns nothing for a marker without a size or one that is not JSON' {
            Set-Content -LiteralPath $script:marker -Value '{ "Generator": "ABC" }'
            Get-RenderMarker | Should -BeNullOrEmpty
            Set-Content -LiteralPath $script:marker -Value 'not json'
            Get-RenderMarker | Should -BeNullOrEmpty
        }
    }

    Context 'Get-TerminalFontFace' {
        It 'finds the face in a settings file that carries comments' {
            $script:repo = $script:work
            New-Item -ItemType Directory -Path (Join-Path $script:work 'terminal') | Out-Null
            Set-Content -LiteralPath (Join-Path $script:work 'terminal\settings.json') -Value @(
                '{'
                '    // Terminal allows comments, which Windows PowerShell cannot parse as JSON.'
                '    "profiles": { "defaults": { "font": { "face": "Test Mono NF" } } }'
                '}'
            )
            Get-TerminalFontFace | Should -Be 'Test Mono NF'
        }
    }

    Context 'Test-SymlinkSupport' {
        It 'answers with a boolean and leaves no probe behind' {
            Test-SymlinkSupport -Directory $script:work | Should -BeOfType [bool]
            @(Get-ChildItem -LiteralPath $script:work -Force).Count | Should -Be 0
        }
    }

    Context 'Invoke-WindowsPowerShell' {
        BeforeEach {
            $script:helpers = Join-Path $script:work 'helper scripts'
            New-Item -ItemType Directory -Path $script:helpers | Out-Null
        }

        It 'returns the output of a helper whose path has spaces, with its arguments intact' {
            $helper = Join-Path $script:helpers 'echo args.ps1'
            Set-Content -LiteralPath $helper -Value @('param([string]$Path)', '"edition: $($PSVersionTable.PSEdition)"', '"path: $Path"')
            Invoke-WindowsPowerShell -Script $helper -Arguments @('-Path', 'C:\some folder\lock screen.png') |
                Should -Be @('edition: Desktop', 'path: C:\some folder\lock screen.png')
        }

        It 'throws with the error text when the helper fails' {
            $helper = Join-Path $script:helpers 'fail.ps1'
            Set-Content -LiteralPath $helper -Value "throw 'the helper broke'"
            { Invoke-WindowsPowerShell -Script $helper } | Should -Throw '*fail.ps1 failed*the helper broke*'
        }

        It 'stops a helper that hangs' {
            $helper = Join-Path $script:helpers 'hang.ps1'
            Set-Content -LiteralPath $helper -Value 'Start-Sleep -Seconds 60'
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            { Invoke-WindowsPowerShell -Script $helper -TimeoutSeconds 3 } | Should -Throw '*did not finish within 3 s*'
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 30
        }
    }

    Context 'Get-ThemeMismatch' {
        BeforeEach {
            $script:desktopImage = 'C:\state\wallpapers\desktop.png'
            $script:personalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
            Mock Get-RegistryValue { 'C:\state\wallpapers\desktop.png' } -ParameterFilter { $Name -eq 'WallPaper' }
            Mock Get-RegistryValue { 0 } -ParameterFilter { $Name -in 'AppsUseLightTheme', 'SystemUsesLightTheme' }
        }

        It 'finds nothing when the wallpaper and dark mode are in place' {
            @(Get-ThemeMismatch).Count | Should -Be 0
        }

        It 'reports a wallpaper the theme did not set' {
            Mock Get-RegistryValue { 'C:\Windows\Web\Wallpaper\Windows\img0.jpg' } -ParameterFilter { $Name -eq 'WallPaper' }
            Get-ThemeMismatch | Should -Be "wallpaper is 'C:\Windows\Web\Wallpaper\Windows\img0.jpg'"
        }

        It 'reports light mode that was left on' {
            Mock Get-RegistryValue { 1 } -ParameterFilter { $Name -eq 'AppsUseLightTheme' }
            Get-ThemeMismatch | Should -Be "AppsUseLightTheme is '1', expected 0"
        }
    }
}
