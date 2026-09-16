#Requires -Version 5.1
<#
.SYNOPSIS
    Returns the primary display's current mode in physical pixels.

.DESCRIPTION
    Reads the mode with EnumDisplaySettings, so DPI scaling does not affect the result.
    Returns nothing when the mode cannot be read, for example in a session without a
    desktop.

.EXAMPLE
    $mode = .\Get-DisplayMode.ps1
    "$($mode.Width)x$($mode.Height) @ $($mode.RefreshRate) Hz"
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param()

$ErrorActionPreference = 'Stop'

if (-not ('DotfilesDisplay' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DotfilesDisplay
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsW(string deviceName, int modeNum, ref DEVMODE devMode);

    // Width, height and refresh rate of the primary display, or null if unknown.
    public static int[] PrimaryMode()
    {
        var dm = new DEVMODE();
        dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        if (EnumDisplaySettingsW(null, -1, ref dm) && dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0)
        {
            return new[] { (int)dm.dmPelsWidth, (int)dm.dmPelsHeight, (int)dm.dmDisplayFrequency };
        }
        return null;
    }
}
'@
}

$mode = [DotfilesDisplay]::PrimaryMode()
if ($mode) {
    [pscustomobject]@{ Width = $mode[0]; Height = $mode[1]; RefreshRate = $mode[2] }
}
