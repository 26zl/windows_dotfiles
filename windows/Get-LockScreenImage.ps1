#Requires -Version 5.1
<#
.SYNOPSIS
    Prints the path of the current lock screen picture.

.DESCRIPTION
    Reads Windows.System.UserProfile.LockScreen.OriginalImageFile. WinRT types are only
    projected in Windows PowerShell 5.1, so run this with powershell.exe; install.ps1
    does that for its -Status report.

.EXAMPLE
    powershell.exe -NoProfile -File .\Get-LockScreenImage.ps1
#>
[CmdletBinding()]
[OutputType([string])]
param()

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'WinRT is not available in PowerShell 7. Run this script with powershell.exe (Windows PowerShell 5.1).'
}

[Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null
$uri = [Windows.System.UserProfile.LockScreen]::OriginalImageFile
if ($uri) {
    ([uri]$uri.AbsoluteUri).LocalPath
}
