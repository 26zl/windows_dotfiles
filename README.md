# windows_dotfiles

[![CI](https://github.com/26zl/windows_dotfiles/actions/workflows/ci.yml/badge.svg)](https://github.com/26zl/windows_dotfiles/actions/workflows/ci.yml)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Windows%2011-0078D6?logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

My Windows 11 look as code: Nord dark theme, a wallpaper rendered for the monitor it lands
on, matching lock screen, transparency and accent colour, Windows Terminal and fastfetch
config. User scope only, reversible, no shell mods.

| Desktop | Lock screen |
| --- | --- |
| ![Desktop](windows/preview.jpg) | ![Lock screen](windows/preview-lockscreen.jpg) |

## Install

```powershell
git clone https://github.com/26zl/windows_dotfiles.git
cd windows_dotfiles
.\install.ps1 -WhatIf   # show every change, make none
.\install.ps1           # apply
.\install.ps1 -Status   # later: what is applied, what has drifted
```

Needs PowerShell 7 with Developer Mode, or an elevated shell, for the symlinks. Add
`-Copy` to copy files instead. `-Skip` leaves steps out, `-InstallTools` also runs
`winget import` for the tool set. A run with nothing to change writes nothing.

## What it does

| Step | Change | How |
| --- | --- | --- |
| Wallpaper | `desktop.png` and `lockscreen.png` at the primary display's resolution | `windows/New-Wallpaper.ps1`, generated, no downloads |
| Theme | Wallpaper, Nord accent `#5E81AC`, dark mode, black cursors, system sounds off | `windows/nord-dark.theme` |
| Appearance | Transparency on, accent on title bars (`-AccentOnTaskbar` for Start and taskbar) | The `HKCU` values Settings writes |
| LockScreen | Dimmed wallpaper as the lock screen picture | The API Settings uses |
| Links | Windows Terminal `settings.json`, fastfetch `config.jsonc` | Symlinks from the `$links` table in `install.ps1` |
| Tools | Windows Terminal, PowerToys, fastfetch | `winget/packages.json`, only with `-InstallTools` |

Anything replaced goes to `%LOCALAPPDATA%\windows_dotfiles\backup\<timestamp>` first,
with `.reg` exports of the registry keys that changed.

To add a config file, put it in the repo and add one line to the `$links` table.
Windows Terminal writes UI changes through the symlink, so they land in the repo.

`terminal/settings.json` keeps only the profiles that exist everywhere: the two built-in
shells, PowerShell, an elevated one, and Git Bash. Terminal builds a dynamic profile
(WSL distributions, Visual Studio, Azure) on any machine where that software is installed,
and it inherits `profiles.defaults`, so the file does not need to list them. Entries for
software a machine lacks are the opposite: they survive as orphans and clutter the profile
list with warning icons.

WSL is the clearest case. Current WSL ships its own profiles as a fragment under
`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\Microsoft.WSL\`, with the right icon and
`startingDirectory`, and that fragment hides the older built-in entry for the same distro.
A `Windows.Terminal.Wsl` profile checked into this file is therefore either hidden or an
orphan, never the one you actually use.

## Per machine

`install.local.psd1` (defaults for `Skip`, `AccentOnTaskbar`, `Copy`) and
`winget/packages.local.json` (extra packages, `winget export` format) are read when present
and ignored by git.

## Fonts

The Terminal profile asks for `Cascadia Mono NF`. Windows Terminal bundles Cascadia Mono
without the Nerd Font glyphs, and no winget source carries the NF build, so this is the one
manual step: take the zip from the
[cascadia-code releases](https://github.com/microsoft/cascadia-code/releases) (2404.23 or
later) and install `CascadiaMonoNF.ttf`. `-Status` reports whether the font is there.

## Revert

Import the `.reg` files from the oldest backup folder, open its `previous.theme`, and move
the backed-up `settings.json` back over the symlink.

## Safety

Everything is `HKCU` or files under the user profile, applied with first-party mechanisms:
a `.theme` file, the Settings lock screen API, `winget`. No `HKLM`, no policies, nothing
injected into `explorer.exe`, no `irm | iex`.

Every Terminal profile starts elevated (`profiles.defaults.elevate` in
`terminal/settings.json`), because that is how I work. Everything launched from such a tab,
package install scripts included, runs as administrator. Remove that one line if you want
ordinary tabs; "PowerShell (Admin)" stays as the elevated profile.

The theme is applied by opening the `.theme` file. From an elevated or windowless session
Windows ignores that, so `install.ps1` then falls back to `windows/Set-Theme.ps1`, which
asks the theme engine (`IThemeManager` in `themeui.dll`, what Settings uses) directly.

## Credits

Ideas from [Windots](https://github.com/scottmckendry/Windots),
[michael-gebis/dotfiles-windows](https://github.com/michael-gebis/dotfiles-windows),
[chezmoi](https://github.com/twpayne/chezmoi) and [dotbot](https://github.com/anishathalye/dotbot).
Colours by [Nord](https://www.nordtheme.com/) (MIT). Shell and editor configs live in
[PowerShellPerfect](https://github.com/26zl/PowerShellPerfect), [nvim](https://github.com/26zl/nvim)
and [vscode_config](https://github.com/26zl/vscode_config).

MIT license.
