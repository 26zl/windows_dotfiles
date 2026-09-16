#Requires -Version 5.1
<#
.SYNOPSIS
    Sets the lock screen picture for the current user.

.DESCRIPTION
    Uses Windows.System.UserProfile.LockScreen, the same WinRT API the Settings app
    calls, so the result is exactly what "Personalize your lock screen > Picture" does:
    user scope, no policy, no "managed by your organization" banner, and reversible
    from Settings at any time.

    WinRT types are only projected in Windows PowerShell 5.1, so run this with
    powershell.exe. install.ps1 does that automatically.

.PARAMETER Path
    The image to use. PNG or JPEG, any size; Windows scales it.

.EXAMPLE
    powershell.exe -NoProfile -File .\Set-LockScreenImage.ps1 -Path "$env:LOCALAPPDATA\windows_dotfiles\wallpapers\lockscreen.png"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'WinRT is not available in PowerShell 7. Run this script with powershell.exe (Windows PowerShell 5.1).'
}

$fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath

# Load the WinRT projections and the interop assembly that provides AsTask().
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null

# WinRT async calls come back as IAsyncOperation/IAsyncAction; bridge them to Tasks.
$extensions = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
$asTaskGeneric = $extensions | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
$asTaskAction = $extensions | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1

function Wait-Operation {
    param($Operation, [Type]$ResultType)
    $task = $asTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    $task.Result
}

function Wait-Action {
    param($Operation)
    $task = $asTaskAction.Invoke($null, @($Operation))
    $task.Wait()
}

$file = Wait-Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($fullPath)) ([Windows.Storage.StorageFile])
Wait-Action ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($file))

$applied = [Windows.System.UserProfile.LockScreen]::OriginalImageFile
Write-Output "Lock screen picture is now $($applied.AbsoluteUri)"
