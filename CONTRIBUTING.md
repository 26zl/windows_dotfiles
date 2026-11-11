# Contributing

These are my dotfiles, so the look is mine, but fixes, safer ways to apply a
setting and support for Windows builds I have not met are welcome. Every
change has to stay user scope, reversible and backed up, as the README's
Safety section describes.

## Setup

You need Windows 11 and PowerShell 7; Windows PowerShell 5.1 has to keep
working too, so `install.ps1` is tested in both. The lint is PSScriptAnalyzer and
the tests use Pester, both pinned to the versions CI uses:

```powershell
git clone https://github.com/26zl/windows_dotfiles.git
cd windows_dotfiles
Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
Install-Module -Name Pester -RequiredVersion 5.7.1 -SkipPublisherCheck -Scope CurrentUser
```

## Before you open a pull request

Run what CI (`.github/workflows/ci.yml`) runs on a `windows-2025` runner:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests              # in pwsh and in powershell.exe
.\windows\New-Wallpaper.ps1 -OutputDirectory "$env:TEMP\wallpapers" -Width 688 -Height 288 -Preview
.\install.ps1 -WhatIf                   # in pwsh and in powershell.exe
.\install.ps1 -Status -Skip LockScreen
```

The tests in `tests\` load the functions from `install.ps1` without running it and only
write to Pester's `TestDrive`. After them, CI applies the installer for real on its
throwaway runner, Theme and LockScreen left out; those steps are not for your own machine.

Warnings count as failures; the only rule turned off is `PSAvoidUsingWriteHost`
(see `PSScriptAnalyzerSettings.psd1`). `terminal\settings.json`,
`winget\packages.json` and `fastfetch\config.jsonc` must parse as JSON; the
fastfetch file may carry full-line `//` comments, nothing else.

## What to keep in mind

- A new config file goes in the repo plus one line in the `$links` table in
  `install.ps1`; nothing else has to know about it.
- Windows Terminal writes UI changes back through the symlink. Read the diff
  before committing, and keep the stubs for the dynamic profiles (the README
  explains why).
- Registry changes are `HKCU` only, written the way the Settings app writes
  them, and exported to `.reg` in the backup folder before they change.
- Formatting follows `.editorconfig`: four spaces, LF line endings, `*.theme`
  in CRLF because the theme parser expects it.
- The previews in the README come from `New-Wallpaper.ps1 -Preview`;
  regenerate them if you change the wallpaper.

## Pull requests and commits

Branch from `main`, open a pull request and describe what changed, why, and
what you ran. Commit messages use a short area prefix and the imperative, for
example `terminal: keep stubs for the dynamic profiles` or
`install: hash files with .NET so a 5.1 dry run is truthful`. Questions and
bugs go in GitHub issues; security problems follow [SECURITY.md](SECURITY.md).
