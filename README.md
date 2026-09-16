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
| Theme | Wallpaper, Nord accent `#5E81AC`, dark mode, black cursors | `windows/nord-dark.theme` |
| Appearance | Transparency on, accent on title bars (`-AccentOnTaskbar` for Start and taskbar) | The `HKCU` values Settings writes |
| LockScreen | Dimmed wallpaper as the lock screen picture | The API Settings uses |
| Links | Windows Terminal `settings.json`, fastfetch `config.jsonc` | Symlinks from the `$links` table in `install.ps1` |
| Tools | Windows Terminal, PowerToys, fastfetch, Cascadia Code | `winget/packages.json`, only with `-InstallTools` |

Anything replaced goes to `%LOCALAPPDATA%\windows_dotfiles\backup\<timestamp>` first,
with `.reg` exports of the registry keys that changed.

To add a config file, put it in the repo and add one line to the `$links` table.
Windows Terminal writes UI changes through the symlink, so they land in the repo.

## Per machine

`install.local.psd1` (defaults for `Skip`, `AccentOnTaskbar`, `Copy`) and
`winget/packages.local.json` (extra packages, `winget export` format) are read when present
and ignored by git.

## Revert

Import the `.reg` files from the oldest backup folder, open its `previous.theme`, and move
the backed-up `settings.json` back over the symlink.

## Safety

Everything is `HKCU` or files under the user profile, applied with first-party mechanisms:
a `.theme` file, the Settings lock screen API, `winget`. No `HKLM`, no policies, nothing
injected into `explorer.exe`, no `irm | iex`. The default Terminal profile is not elevated;
"PowerShell (Admin)" is a separate profile.

## Credits

Ideas from [Windots](https://github.com/scottmckendry/Windots),
[michael-gebis/dotfiles-windows](https://github.com/michael-gebis/dotfiles-windows),
[chezmoi](https://github.com/twpayne/chezmoi) and [dotbot](https://github.com/anishathalye/dotbot).
Colours by [Nord](https://www.nordtheme.com/) (MIT). Shell and editor configs live in
[PowerShellPerfect](https://github.com/26zl/PowerShellPerfect), [nvim](https://github.com/26zl/nvim)
and [vscode_config](https://github.com/26zl/vscode_config).

MIT license.
