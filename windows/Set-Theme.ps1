#Requires -Version 5.1
<#
.SYNOPSIS
    Applies a .theme file through the Windows theme engine, the way Settings does.

.DESCRIPTION
    Opening a .theme file is the documented route, and install.ps1 tries that first. It
    does nothing from an elevated or windowless session, because the shell hands the file
    to Settings in the interactive user's context. This helper asks the theme engine's
    IThemeManager (themeui.dll) directly instead. The interface is undocumented, so it
    stays the fallback.

.PARAMETER Path
    The .theme file to apply.

.EXAMPLE
    .\Set-Theme.ps1 -Path "$env:LOCALAPPDATA\Microsoft\Windows\Themes\nord-dark.theme"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$theme = (Resolve-Path -LiteralPath $Path).ProviderPath

if (-not ('Dotfiles.ThemeEngine' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Dotfiles
{
    [ComImport, Guid("0646EBBE-C1B7-4045-8FD0-FFD65D3FC792"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IThemeManager
    {
        [return: MarshalAs(UnmanagedType.IUnknown)]
        object GetCurrentTheme();
        void ApplyTheme([In, MarshalAs(UnmanagedType.BStr)] string themePath);
    }

    [ComImport, Guid("C04B329E-5823-4415-9C93-BA44688947B0")]
    internal class ThemeManager { }

    public static class ThemeEngine
    {
        // The theme manager is apartment-threaded; give it an STA thread whatever the host runs on.
        public static void Apply(string themePath)
        {
            Exception failure = null;
            var worker = new Thread(() =>
            {
                try
                {
                    var manager = (IThemeManager)new ThemeManager();
                    try { manager.ApplyTheme(themePath); }
                    finally { Marshal.ReleaseComObject(manager); }
                }
                catch (Exception e) { failure = e; }
            });
            worker.SetApartmentState(ApartmentState.STA);
            worker.Start();
            worker.Join();
            if (failure != null) { throw failure; }
        }
    }
}
'@
}

[Dotfiles.ThemeEngine]::Apply($theme)
