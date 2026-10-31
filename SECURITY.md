# Security policy

## Reporting a vulnerability

Report security problems privately through GitHub:
[Report a vulnerability](https://github.com/26zl/windows_dotfiles/security/advisories/new)
(the Security tab of this repository). Do not open a public issue for
something that could be exploited before it is fixed. Expect a first reply
within seven days. The fix lands on `main`, and the advisory is published
once it is in.

Ordinary bugs, a step that drifts or a profile that is wrong on your machine,
go in [GitHub issues](https://github.com/26zl/windows_dotfiles/issues).

## What counts

The scripts promise to stay in user scope, to be reversible and to download
nothing unless asked. A private report is right when that promise breaks,
for example:

- `install.ps1` or a script under `windows\` writing outside `HKCU` and the
  user profile, touching HKLM, policies or services, or replacing something
  without first moving it to `%LOCALAPPDATA%\windows_dotfiles\backup\`.
- A dry run (`-WhatIf`) or `-Status` that changes anything.
- Anything downloaded or executed that the README does not list; the only
  download is `winget import`, and only with `-InstallTools`.
- A linked config (`terminal\settings.json`, `fastfetch\config.jsonc`) that
  runs commands beyond the elevated profiles the README documents.

Problems in Windows Terminal, PowerToys, fastfetch, winget or Windows itself
belong with those projects.

## Supported versions

There are no releases; the current `main` branch is what is supported. Run
`git pull` and `.\install.ps1` again to pick up fixes.
