#Requires -Version 5.1
<#
.SYNOPSIS
    Applies these dotfiles to the current Windows user, or reports drift with -Status.

.DESCRIPTION
    Every change is user scope (HKCU and files under the user profile), reversible, and
    made through first-party mechanisms only:

      - a .theme file for wallpaper, accent colour, dark mode, cursors and the sound scheme
      - the same WinRT API the Settings app uses for the lock screen picture
      - the registry values Settings itself writes for transparency and accent placement
      - symlinks for configuration files, listed once in the $links table below
      - winget import for the optional tool set in winget\packages.json

    Nothing touches HKLM, group policy, Defender, services or explorer.exe, and nothing
    is downloaded unless -InstallTools is given. A run that finds everything in place
    changes nothing and writes nothing. Whatever is about to be replaced is moved to
    %LOCALAPPDATA%\windows_dotfiles\backup\<timestamp> first, next to .reg exports of the
    registry keys that change.

    Machine-specific defaults for Skip, AccentOnTaskbar and Copy can live in
    install.local.psd1 next to this script. That file is not tracked by git, and
    parameters given on the command line always win.

.PARAMETER Status
    Report what is applied, missing or drifted, and change nothing. -Skip narrows the
    report and -InstallTools adds the tool set to it.

.PARAMETER Skip
    Steps to leave out: Wallpaper, Theme, Appearance, LockScreen, Links.

.PARAMETER Copy
    Copy configuration files into place instead of symlinking them. For machines
    without Developer Mode or administrator rights; edits then have to be copied back
    into the repo by hand.

.PARAMETER AccentOnTaskbar
    Also tint Start and the taskbar with the accent colour. Title bars and window
    borders always get it.

.PARAMETER InstallTools
    Install the packages in winget\packages.json, plus winget\packages.local.json when
    present, with winget import. Packages that are already installed are left alone.

.EXAMPLE
    .\install.ps1 -WhatIf
    Lists every change without making any.

.EXAMPLE
    .\install.ps1 -Status
    Shows what is applied and what has drifted.

.EXAMPLE
    .\install.ps1 -Skip LockScreen -AccentOnTaskbar

.NOTES
    Symlinks need PowerShell 7 with Developer Mode enabled, or an elevated shell.
    Use -Copy otherwise.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Status,

    [ValidateSet('Wallpaper', 'Theme', 'Appearance', 'LockScreen', 'Links')]
    [string[]]$Skip = @(),

    [switch]$Copy,

    [switch]$AccentOnTaskbar,

    [switch]$InstallTools
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    throw 'These dotfiles configure Windows; nothing to do on this platform.'
}

$repo = $PSScriptRoot
$steps = 'Wallpaper', 'Theme', 'Appearance', 'LockScreen', 'Links'

# Machine-specific defaults, not tracked by git. Explicit parameters win.
$localConfig = Join-Path $repo 'install.local.psd1'
if (Test-Path -LiteralPath $localConfig) {
    $local = Import-PowerShellDataFile -LiteralPath $localConfig
    if ($local.ContainsKey('Skip') -and -not $PSBoundParameters.ContainsKey('Skip')) {
        $localSkip = @([string[]]$local.Skip)
        foreach ($step in $localSkip) {
            if ($step -notin $steps) { throw "install.local.psd1: unknown step '$step' in Skip. Valid: $($steps -join ', ')." }
        }
        $Skip = $localSkip
    }
    if ($local.ContainsKey('AccentOnTaskbar') -and -not $PSBoundParameters.ContainsKey('AccentOnTaskbar')) { $AccentOnTaskbar = [bool]$local.AccentOnTaskbar }
    if ($local.ContainsKey('Copy') -and -not $PSBoundParameters.ContainsKey('Copy')) { $Copy = [bool]$local.Copy }
}
$useCopy = [bool]$Copy
$taskbarAccent = [bool]$AccentOnTaskbar

# Paths
$stateDir     = Join-Path $env:LOCALAPPDATA 'windows_dotfiles'
$wallDir      = Join-Path $stateDir 'wallpapers'
$backupDir    = Join-Path $stateDir ('backup\{0:yyyyMMdd-HHmmss}' -f (Get-Date))
$themesDir    = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes'
$themeSource  = Join-Path $repo 'windows\nord-dark.theme'
$themeDest    = Join-Path $themesDir 'nord-dark.theme'
$desktopImage = Join-Path $wallDir 'desktop.png'
$lockImage    = Join-Path $wallDir 'lockscreen.png'

$themesKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
$personalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$dwmKey         = 'HKCU:\Software\Microsoft\Windows\DWM'
$wallpapersKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'

# Configuration files and where they belong. Source is relative to the repo. When says
# what has to exist for the link to apply: the destination's folder (the app is
# installed), the destination file itself (an unpackaged build in use), or nothing.
$links = @(
    @{ Source = 'terminal\settings.json'; Destination = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'; When = 'ParentExists' }
    @{ Source = 'terminal\settings.json'; Destination = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'; When = 'ParentExists' }
    @{ Source = 'terminal\settings.json'; Destination = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'; When = 'FileExists' }
    @{ Source = 'fastfetch\config.jsonc'; Destination = Join-Path $HOME '.config\fastfetch\config.jsonc'; When = 'Always' }
)

# Registry values the Appearance step owns.
$registryTargets = @(
    @{ Label = 'Transparency';         Path = $personalizeKey; Name = 'EnableTransparency'; Value = 1 }
    @{ Label = 'Accent on taskbar';    Path = $personalizeKey; Name = 'ColorPrevalence';    Value = [int]$taskbarAccent }
    @{ Label = 'Accent on title bars'; Path = $dwmKey;         Name = 'ColorPrevalence';    Value = 1 }
)

$packageFiles = @(@('winget\packages.json', 'winget\packages.local.json') |
    ForEach-Object { Join-Path $repo $_ } |
    Where-Object { Test-Path -LiteralPath $_ })

$script:cmdlet       = $PSCmdlet
$script:changes      = [System.Collections.Generic.List[string]]::new()
$script:backedUpKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:driftCount   = 0

# Helpers
function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }
function Write-Done { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "    $Text" -ForegroundColor Yellow }

# Runs one change through the script's ShouldProcess so -WhatIf and -Confirm cover every step.
function Invoke-Change {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][scriptblock]$Do
    )
    if ($script:cmdlet.ShouldProcess($Target, $Action)) {
        & $Do
        $script:changes.Add("$Action -> $Target")
        return $true
    }
    return $false
}

function Initialize-BackupDirectory {
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
}

function Get-FileHashSafe {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    # .NET rather than Get-FileHash: Windows PowerShell implements that cmdlet as a script whose
    # ForEach-Object honours -WhatIf and returns nothing, so "powershell -File install.ps1 -WhatIf"
    # saw every file as changed. Same output format: upper-case hex.
    try {
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $stream = [System.IO.File]::OpenRead($fullPath)
        try {
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try { return ([System.BitConverter]::ToString($sha256.ComputeHash($stream)) -replace '-', '') }
            finally { $sha256.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }
}

function Test-SameContent {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$PathA, [Parameter(Mandatory)][string]$PathB)
    $a = Get-FileHashSafe -Path $PathA
    $b = Get-FileHashSafe -Path $PathB
    return [bool]($a -and $b -and $a -eq $b)
}

function Get-RegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).GetValue($Name, $null) }
    return $null
}

# Moves a real file (never a link) into the backup folder. Returns the backup path.
function Backup-Item {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType) { return $null }

    $dest = Join-Path $backupDir $item.Name
    $suffix = 1
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $backupDir ('{0}.{1}{2}' -f $item.BaseName, $suffix++, $item.Extension)
    }
    $moved = Invoke-Change -Target $Path -Action "Move to backup $dest" -Do {
        Initialize-BackupDirectory
        Move-Item -LiteralPath $Path -Destination $dest -Force
    }
    if ($moved) { return $dest }
    return $null
}

# Exports a registry key once per run, right before its first change.
function Backup-RegistryKey {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Key)

    if ($script:backedUpKeys.Contains($Key)) { return }
    $script:backedUpKeys.Add($Key) | Out-Null

    $regKey = $Key -replace '^HKCU:\\', 'HKCU\'
    if (-not (Test-Path -LiteralPath $Key)) {
        Write-Note "$regKey does not exist yet; nothing to back up"
        return
    }
    $name = (($regKey -replace '^HKCU\\', '') -replace '[\\ ]', '-').ToLower()
    $file = Join-Path $backupDir "$name.reg"
    Invoke-Change -Target $regKey -Action "Export to $file" -Do {
        Initialize-BackupDirectory
        & reg.exe export $regKey $file /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg.exe export of $regKey failed with exit code $LASTEXITCODE." }
    } | Out-Null
}

function Set-RegistryDword {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )
    $current = Get-RegistryValue -Path $Path -Name $Name
    if ($null -ne $current -and [int]$current -eq $Value) {
        Write-Note "$Name is already $Value"
        return
    }
    Backup-RegistryKey -Key $Path
    Invoke-Change -Target "$Path\$Name" -Action "Set to $Value" -Do {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type DWord
    } | Out-Null
}

# Tells Explorer and open apps that a setting changed; the same broadcast Settings sends.
function Send-SettingChange {
    param([Parameter(Mandatory)][string]$Area)
    if (-not ('Dotfiles.Native' -as [type])) {
        Add-Type -Namespace Dotfiles -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
'@
    }
    $hwndBroadcast = [IntPtr]0xFFFF
    $wmSettingChange = 0x001A
    $smtoAbortIfHung = 0x0002
    $result = [UIntPtr]::Zero
    [Dotfiles.Native]::SendMessageTimeoutW($hwndBroadcast, $wmSettingChange, [UIntPtr]::Zero, $Area, $smtoAbortIfHung, 5000, [ref]$result) | Out-Null
}

# Runs a helper that needs WinRT, which only Windows PowerShell 5.1 projects.
function Invoke-WindowsPowerShell {
    param(
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Arguments = @()
    )
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output = & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path -Leaf $Script) failed: $($output -join ' ')" }
    return $output
}

function Test-LinkApplicable {
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Link)
    switch ($Link.When) {
        'Always'       { return $true }
        'ParentExists' { return (Test-Path -LiteralPath (Split-Path -Parent $Link.Destination)) }
        'FileExists'   { return (Test-Path -LiteralPath $Link.Destination) }
    }
    return $false
}

# What is at a link destination: linked (to the repo file), copied (an identical real
# file), stale-link (a symlink elsewhere), real-file (differs from the repo) or missing.
function Get-LinkState {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $src = (Resolve-Path -LiteralPath $Source).ProviderPath
    if (-not (Test-Path -LiteralPath $Destination)) { return @{ State = 'missing'; Detail = ''; Target = $null } }

    $existing = Get-Item -LiteralPath $Destination -Force
    if ($existing.LinkType -eq 'SymbolicLink') {
        $target = [string](@($existing.Target)[0])
        $resolved = if ($target) { Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue } else { $null }
        if ($resolved -and $resolved.ProviderPath -ieq $src) { return @{ State = 'linked'; Detail = "-> $src"; Target = $target } }
        return @{ State = 'stale-link'; Detail = "points to $target"; Target = $target }
    }
    if (Test-SameContent -PathA $Destination -PathB $src) { return @{ State = 'copied'; Detail = 'real file, identical to the repo'; Target = $null } }
    return @{ State = 'real-file'; Detail = 'real file, differs from the repo'; Target = $null }
}

# Puts a symlink (or a copy with -Copy) to a repo file at $Destination, backing up
# whatever real file is there first. Idempotent: a correct link or copy is left alone.
function Install-Link {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $src = (Resolve-Path -LiteralPath $Source).ProviderPath
    $state = Get-LinkState -Source $src -Destination $Destination
    $backup = $null

    switch ($state.State) {
        'linked' {
            if (-not $useCopy) { Write-Note "already linked: $Destination"; return }
            Invoke-Change -Target $Destination -Action 'Remove link (copy mode)' -Do { Remove-Item -LiteralPath $Destination -Force } | Out-Null
        }
        'copied' {
            if ($useCopy) { Write-Note "already up to date: $Destination"; return }
            $backup = Backup-Item -Path $Destination
        }
        'stale-link' {
            Invoke-Change -Target $Destination -Action "Remove stale link (pointed to $($state.Target))" -Do {
                Initialize-BackupDirectory
                Add-Content -LiteralPath (Join-Path $backupDir 'removed-links.txt') -Value "$Destination -> $($state.Target)"
                Remove-Item -LiteralPath $Destination -Force
            } | Out-Null
        }
        'real-file' {
            $backup = Backup-Item -Path $Destination
        }
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        Invoke-Change -Target $parent -Action 'Create directory' -Do {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        } | Out-Null
    }

    if ($useCopy) {
        Invoke-Change -Target $Destination -Action "Copy from $src" -Do {
            Copy-Item -LiteralPath $src -Destination $Destination -Force
        } | Out-Null
        return
    }

    try {
        Invoke-Change -Target $Destination -Action "Link to $src" -Do {
            New-Item -ItemType SymbolicLink -Path $Destination -Target $src | Out-Null
        } | Out-Null
    }
    catch {
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $Destination -Force
            Write-Warn "restored the original $Destination"
        }
        throw "Could not create a symlink at $Destination ($($_.Exception.Message)). Enable Developer Mode, run elevated, or use -Copy."
    }
}

# The render marker New-Wallpaper.ps1 leaves next to the images, or $null.
function Get-RenderMarker {
    [OutputType([pscustomobject])]
    param()
    $marker = Join-Path $wallDir 'render.json'
    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    try { $info = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json } catch { return $null }
    foreach ($name in 'Generator', 'Width', 'Height') {
        if (-not $info.PSObject.Properties[$name]) { return $null }
    }
    return $info
}

# True when both images exist and were rendered by this generator for the current display.
function Test-WallpaperCurrent {
    [OutputType([bool])]
    param()
    if (-not ((Test-Path -LiteralPath $desktopImage) -and (Test-Path -LiteralPath $lockImage))) { return $false }
    $info = Get-RenderMarker
    if (-not $info) { return $false }
    $generator = Get-FileHashSafe -Path (Join-Path $repo 'windows\New-Wallpaper.ps1')
    if (-not $generator -or $info.Generator -ne $generator) { return $false }
    $mode = & (Join-Path $repo 'windows\Get-DisplayMode.ps1')
    if ($mode -and ([int]$info.Width -ne $mode.Width -or [int]$info.Height -ne $mode.Height)) { return $false }
    return $true
}

# Width and height from a PNG header, without loading the image.
function Get-PngSize {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [byte[]]::new(24)
    $stream = [System.IO.File]::OpenRead($Path)
    try { $read = $stream.Read($bytes, 0, 24) }
    finally { $stream.Dispose() }
    if ($read -lt 24 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) { return $null }
    # Widen to int before shifting; a shifted [byte] stays a byte and loses the high bits.
    $w = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor [int]$bytes[19]
    $h = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor [int]$bytes[23]
    return [pscustomobject]@{ Width = $w; Height = $h }
}

function Get-PackageId {
    [OutputType([string])]
    param([string[]]$Files)
    foreach ($file in $Files) {
        $manifest = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        foreach ($source in $manifest.Sources) {
            foreach ($package in $source.Packages) { $package.PackageIdentifier }
        }
    }
}

# The font family terminal\settings.json asks for. Read with a pattern because Windows
# PowerShell cannot parse the comments Terminal allows in that file.
function Get-TerminalFontFace {
    [OutputType([string])]
    param()
    $settings = Get-Content -LiteralPath (Join-Path $repo 'terminal\settings.json') -Raw
    if ($settings -match '"face"\s*:\s*"([^"]+)"') { return $Matches[1] }
    return $null
}

function Test-FontInstalled {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Family)
    Add-Type -AssemblyName System.Drawing
    $fonts = [System.Drawing.Text.InstalledFontCollection]::new()
    try { return [bool]($fonts.Families | Where-Object { $_.Name -eq $Family }) }
    finally { $fonts.Dispose() }
}

function Install-PackageSet {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Files)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is not available; install "App Installer" from the Microsoft Store first.'
    }
    foreach ($file in $Files) {
        Invoke-Change -Target $file -Action 'winget import (missing packages only)' -Do {
            & winget import --import-file $file --no-upgrade --accept-source-agreements --accept-package-agreements --ignore-unavailable --disable-interactivity | Out-Host
            # -1978335189 (0x8A15002B) means nothing was applicable, for example everything was installed already.
            if ($LASTEXITCODE -notin 0, -1978335189) { Write-Warn "winget returned $LASTEXITCODE for $file" }
        } | Out-Null
    }
}

function Write-StatusLine {
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('ok', 'drift', 'missing', 'unknown')][string]$State,
        [string]$Detail = ''
    )
    $colour = switch ($State) { 'ok' { 'Green' } 'unknown' { 'DarkGray' } default { 'Yellow' } }
    if ($State -in 'drift', 'missing') { $script:driftCount++ }
    Write-Host ('{0,-22} ' -f $Item) -NoNewline
    Write-Host ('{0,-8} ' -f $State) -ForegroundColor $colour -NoNewline
    Write-Host $Detail -ForegroundColor DarkGray
}

# Read-only report of every managed item.
function Show-Status {
    Write-Host ('{0,-22} {1,-8} {2}' -f 'Item', 'State', 'Detail') -ForegroundColor White

    if ($Skip -notcontains 'Wallpaper') {
        $mode = & (Join-Path $repo 'windows\Get-DisplayMode.ps1')
        $info = Get-RenderMarker
        $generator = Get-FileHashSafe -Path (Join-Path $repo 'windows\New-Wallpaper.ps1')
        foreach ($image in $desktopImage, $lockImage) {
            $name = Split-Path -Leaf $image
            if (-not (Test-Path -LiteralPath $image)) { Write-StatusLine -Item 'Wallpaper' -State 'missing' -Detail "$name not rendered"; continue }
            $size = Get-PngSize -Path $image
            if (-not $size) { Write-StatusLine -Item 'Wallpaper' -State 'drift' -Detail "$name is not a PNG"; continue }
            if ($mode -and ($size.Width -ne $mode.Width -or $size.Height -ne $mode.Height)) {
                Write-StatusLine -Item 'Wallpaper' -State 'drift' -Detail "$name is $($size.Width)x$($size.Height), display is $($mode.Width)x$($mode.Height)"
            }
            elseif (-not $info -or $info.Generator -ne $generator) {
                Write-StatusLine -Item 'Wallpaper' -State 'drift' -Detail "$name was rendered by an older generator"
            }
            else { Write-StatusLine -Item 'Wallpaper' -State 'ok' -Detail "$name $($size.Width)x$($size.Height)" }
        }
    }

    if ($Skip -notcontains 'Theme') {
        $activeTheme = [string](Get-RegistryValue -Path $themesKey -Name 'CurrentTheme')
        $themeInstalled = (Test-Path -LiteralPath $themeDest) -and (Test-SameContent -PathA $themeDest -PathB $themeSource)
        if ($themeInstalled -and $activeTheme -ieq $themeDest) { Write-StatusLine -Item 'Theme' -State 'ok' -Detail 'Nord Dark is the active theme' }
        elseif (-not $themeInstalled) { Write-StatusLine -Item 'Theme' -State 'missing' -Detail 'theme file not installed or outdated' }
        else { Write-StatusLine -Item 'Theme' -State 'drift' -Detail "active theme is $activeTheme" }

        $type = Get-RegistryValue -Path $wallpapersKey -Name 'BackgroundType'
        if ($null -ne $type -and [int]$type -eq 0) { Write-StatusLine -Item 'Background type' -State 'ok' -Detail 'Picture' }
        else { Write-StatusLine -Item 'Background type' -State 'drift' -Detail "BackgroundType is $type (0 = Picture)" }
    }

    if ($Skip -notcontains 'Appearance') {
        foreach ($target in $registryTargets) {
            $value = Get-RegistryValue -Path $target.Path -Name $target.Name
            if ($null -ne $value -and [int]$value -eq $target.Value) { Write-StatusLine -Item $target.Label -State 'ok' -Detail "$($target.Name) = $value" }
            else { Write-StatusLine -Item $target.Label -State 'drift' -Detail "$($target.Name) is $value, expected $($target.Value)" }
        }
    }

    if ($Skip -notcontains 'LockScreen') {
        try { $current = [string](@(Invoke-WindowsPowerShell -Script (Join-Path $repo 'windows\Get-LockScreenImage.ps1')) | Select-Object -Last 1) }
        catch { $current = $null }
        if ($current -ieq $lockImage) { Write-StatusLine -Item 'Lock screen' -State 'ok' -Detail $current }
        elseif (-not $current) { Write-StatusLine -Item 'Lock screen' -State 'unknown' -Detail 'could not read the current picture' }
        else { Write-StatusLine -Item 'Lock screen' -State 'drift' -Detail "picture is $current" }
    }

    if ($Skip -notcontains 'Links') {
        foreach ($link in $links) {
            if (-not (Test-LinkApplicable -Link $link)) { continue }
            $state = Get-LinkState -Source (Join-Path $repo $link.Source) -Destination $link.Destination
            $item = Split-Path -Leaf $link.Source
            switch ($state.State) {
                'linked'     { Write-StatusLine -Item $item -State 'ok' -Detail "linked $($link.Destination)" }
                'copied'     { Write-StatusLine -Item $item -State $(if ($useCopy) { 'ok' } else { 'drift' }) -Detail "$($state.Detail): $($link.Destination)" }
                'stale-link' { Write-StatusLine -Item $item -State 'drift' -Detail "$($state.Detail): $($link.Destination)" }
                'real-file'  { Write-StatusLine -Item $item -State 'drift' -Detail "$($state.Detail): $($link.Destination)" }
                'missing'    { Write-StatusLine -Item $item -State 'missing' -Detail $link.Destination }
            }
        }
        $face = Get-TerminalFontFace
        if ($face) {
            if (Test-FontInstalled -Family $face) { Write-StatusLine -Item 'Terminal font' -State 'ok' -Detail $face }
            else { Write-StatusLine -Item 'Terminal font' -State 'missing' -Detail "$face is not installed; see README, Fonts" }
        }
    }

    if ($InstallTools) {
        $ids = @(Get-PackageId -Files $packageFiles)
        if ($ids.Count -gt 0 -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            $installed = (& winget list --accept-source-agreements 2>$null) -join "`n"
            foreach ($id in $ids) {
                if ($installed -match [regex]::Escape($id)) { Write-StatusLine -Item 'Tool' -State 'ok' -Detail $id }
                else { Write-StatusLine -Item 'Tool' -State 'missing' -Detail $id }
            }
        }
    }

    Write-Host ''
    if ($script:driftCount -eq 0) { Write-Host 'Everything is applied.' -ForegroundColor Green }
    else { Write-Host "$($script:driftCount) item(s) need attention; run .\install.ps1 to apply." -ForegroundColor Yellow }
}

# Run
Write-Host ''
Write-Host 'windows_dotfiles' -ForegroundColor White
Write-Note "repo:  $repo"
Write-Note "state: $stateDir"
if (Test-Path -LiteralPath $localConfig) { Write-Note "local: $localConfig" }
if ($Status) { Write-Host ''; Show-Status; return }
if ($WhatIfPreference) { Write-Warn 'dry run: nothing will be changed' }
Write-Host ''

if ($InstallTools) {
    Write-Step 'Tools (winget import)'
    if ($packageFiles.Count -eq 0) { Write-Note 'no winget\packages.json found; skipped' }
    else { Install-PackageSet -Files $packageFiles }
}

if ($Skip -notcontains 'Wallpaper') {
    Write-Step 'Wallpapers at the primary display resolution'
    if (Test-WallpaperCurrent) {
        Write-Note 'already rendered for this display by this generator'
    }
    else {
        Invoke-Change -Target $wallDir -Action 'Render desktop.png and lockscreen.png' -Do {
            & (Join-Path $repo 'windows\New-Wallpaper.ps1') -OutputDirectory $wallDir
        } | Out-Null
    }
}

if ($Skip -notcontains 'Theme') {
    Write-Step 'Nord Dark theme (wallpaper, accent, dark mode, cursors, no system sounds)'
    if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $desktopImage)) {
        Write-Warn "$desktopImage is missing, so Windows will show a solid colour until the Wallpaper step runs"
    }
    $activeTheme = [string](Get-RegistryValue -Path $themesKey -Name 'CurrentTheme')
    $themeInstalled = (Test-Path -LiteralPath $themeDest) -and (Test-SameContent -PathA $themeDest -PathB $themeSource)
    if ($themeInstalled -and $activeTheme -ieq $themeDest) {
        Write-Note 'already applied'
    }
    else {
        Backup-RegistryKey -Key 'HKCU:\Control Panel\Desktop'
        if ($activeTheme -and ($activeTheme -ine $themeDest) -and (Test-Path -LiteralPath $activeTheme)) {
            Invoke-Change -Target $activeTheme -Action "Copy to $backupDir\previous.theme" -Do {
                Initialize-BackupDirectory
                Copy-Item -LiteralPath $activeTheme -Destination (Join-Path $backupDir 'previous.theme') -Force
            } | Out-Null
        }
        if ($env:LOCALAPPDATA -ine (Join-Path $env:USERPROFILE 'AppData\Local')) {
            Write-Warn "LOCALAPPDATA is redirected to $env:LOCALAPPDATA; the theme expects the wallpaper under %USERPROFILE%\AppData\Local"
        }
        Invoke-Change -Target $themeDest -Action "Install theme file from $themeSource" -Do {
            New-Item -ItemType Directory -Path $themesDir -Force | Out-Null
            Copy-Item -LiteralPath $themeSource -Destination $themeDest -Force
        } | Out-Null

        $settingsBefore = @(Get-Process -Name SystemSettings -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        Invoke-Change -Target 'Windows personalization' -Action 'Apply the theme (Settings opens briefly)' -Do {
            Start-Process -FilePath $themeDest
            $deadline = (Get-Date).AddSeconds(20)
            $applied = $false
            do {
                Start-Sleep -Milliseconds 500
                $current = [string](Get-RegistryValue -Path $themesKey -Name 'CurrentTheme')
                if ($current -ieq $themeDest) { $applied = $true }
            } until ($applied -or (Get-Date) -gt $deadline)
            if (-not $applied) {
                # Opening the file does nothing from an elevated or windowless session; ask the theme engine.
                try {
                    & (Join-Path $repo 'windows\Set-Theme.ps1') -Path $themeDest
                    $applied = ([string](Get-RegistryValue -Path $themesKey -Name 'CurrentTheme')) -ieq $themeDest
                }
                catch { Write-Warn "theme engine fallback failed: $($_.Exception.Message)" }
            }
            if ($applied) { Write-Done 'theme applied' }
            else { Write-Warn 'Windows did not confirm the theme within 20 s; check Settings > Personalization > Themes' }

            # Close only the Settings window the theme launch opened, never one the user already had.
            # Settings starts after the theme is applied, so give it a moment to show up.
            $closeBy = (Get-Date).AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 500
                $opened = @(Get-Process -Name SystemSettings -ErrorAction SilentlyContinue | Where-Object { $settingsBefore -notcontains $_.Id })
            } until ($opened.Count -gt 0 -or (Get-Date) -gt $closeBy)
            if ($opened.Count -gt 0) {
                Start-Sleep -Seconds 2
                $opened | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        } | Out-Null
    }

    # Settings tracks the background type separately (0 = Picture, 3 = Spotlight) and a theme does not update it.
    Set-RegistryDword -Path $wallpapersKey -Name 'BackgroundType' -Value 0
}

if ($Skip -notcontains 'Appearance') {
    Write-Step 'Transparency effects and accent colour placement'
    $before = $script:changes.Count
    foreach ($target in $registryTargets) {
        Set-RegistryDword -Path $target.Path -Name $target.Name -Value $target.Value
    }
    if ($script:changes.Count -gt $before -or $WhatIfPreference) {
        Invoke-Change -Target 'running applications' -Action 'Broadcast the colour change' -Do {
            Send-SettingChange -Area 'ImmersiveColorSet'
        } | Out-Null
    }
}

if ($Skip -notcontains 'LockScreen') {
    Write-Step 'Lock screen picture'
    if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $lockImage)) {
        Write-Warn "skipped: $lockImage is missing (run the Wallpaper step first)"
    }
    else {
        $current = $null
        if (-not $WhatIfPreference) {
            try { $current = [string](@(Invoke-WindowsPowerShell -Script (Join-Path $repo 'windows\Get-LockScreenImage.ps1')) | Select-Object -Last 1) }
            catch { $current = $null }
        }
        if ($current -ieq $lockImage) {
            Write-Note 'already applied'
        }
        else {
            Invoke-Change -Target $lockImage -Action 'Set as lock screen picture' -Do {
                $output = Invoke-WindowsPowerShell -Script (Join-Path $repo 'windows\Set-LockScreenImage.ps1') -Arguments @('-Path', $lockImage)
                Write-Done ([string](@($output) | Select-Object -Last 1))
            } | Out-Null
        }
    }
}

if ($Skip -notcontains 'Links') {
    Write-Step 'Configuration files'
    $applied = 0
    foreach ($link in $links) {
        if (-not (Test-LinkApplicable -Link $link)) { continue }
        $applied++
        Install-Link -Source (Join-Path $repo $link.Source) -Destination $link.Destination
    }
    if ($applied -eq 0) { Write-Note 'nothing applies on this machine' }
    if (-not (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
        Write-Note 'fastfetch is not installed; its config is in place for when it is (winget import, or -InstallTools)'
    }
    $face = Get-TerminalFontFace
    if ($face -and -not (Test-FontInstalled -Family $face)) {
        Write-Warn "$face is not installed, so Windows Terminal falls back to another font; see README, Fonts"
    }
}

Write-Host ''
if ($WhatIfPreference) {
    Write-Host 'Dry run finished; nothing was changed.' -ForegroundColor Yellow
    return
}
if ($script:changes.Count -eq 0) {
    Write-Host 'Nothing to do; everything was already applied.' -ForegroundColor Green
    return
}
Write-Host ("Done: {0} change(s)." -f $script:changes.Count) -ForegroundColor Green
if (Test-Path -LiteralPath $backupDir) {
    Write-Host "Backups: $backupDir" -ForegroundColor White
    Write-Note 'to revert: double-click the .reg files, open previous.theme, and move a backed-up settings.json back into place'
}
Write-Note 'a new lock screen picture shows the next time the PC locks (Win+L)'
