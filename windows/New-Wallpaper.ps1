#Requires -Version 5.1
<#
.SYNOPSIS
    Renders the Nord-themed desktop and lock screen wallpapers.

.DESCRIPTION
    The images are generated procedurally, so nothing is downloaded and there are no
    licensing questions. They are rendered at the primary display's native resolution
    (or at -Width x -Height when given), which avoids the cropping a 16:9 stock image
    gets on an ultrawide monitor. The output is deterministic for a given size and seed.

    desktop.png             dark Nord "polar night" gradient with soft frost and aurora glows
    lockscreen.png          the same composition, dimmed with a vignette so the clock stays legible
    preview.jpg             1280 px wide preview of the desktop image (only with -Preview)
    preview-lockscreen.jpg  the same for the lock screen image (only with -Preview)

.PARAMETER OutputDirectory
    Folder to write the images into. Created if missing.

.PARAMETER Width
    Image width in pixels. Defaults to the primary display's current mode.

.PARAMETER Height
    Image height in pixels. Defaults to the primary display's current mode.

.PARAMETER Seed
    Seed for the dither noise, so a render is reproducible.

.PARAMETER Preview
    Also write the two preview JPEGs.

.EXAMPLE
    .\New-Wallpaper.ps1 -OutputDirectory "$env:LOCALAPPDATA\windows_dotfiles\wallpapers"

.EXAMPLE
    .\New-Wallpaper.ps1 -OutputDirectory .\out -Width 2560 -Height 1440 -Preview
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [ValidateRange(320, 15360)]
    [int]$Width,

    [ValidateRange(200, 8640)]
    [int]$Height,

    [int]$Seed = 26,

    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$rendererSource = @'
using System;

public static class DotfilesWallpaper
{
    private struct Glow
    {
        public double X, Y, Sigma, Stretch, Strength;
        public double R, G, B;
        // x, y: centre as a fraction of width/height. sigma: radius as a fraction of width.
        // stretch: > 1 widens the glow horizontally, like an aurora band.
        public Glow(double x, double y, double sigma, double stretch, double strength, int rgb)
        {
            X = x; Y = y; Sigma = sigma; Stretch = stretch; Strength = strength;
            R = (rgb >> 16) & 0xFF; G = (rgb >> 8) & 0xFF; B = rgb & 0xFF;
        }
    }

    private static double Lerp(double a, double b, double t) { return a + (b - a) * t; }

    private static byte Clamp(double v)
    {
        if (v < 0) return 0;
        if (v > 255) return 255;
        return (byte)Math.Round(v);
    }

    // Returns a top-down 24bpp BGR buffer with the given stride.
    public static byte[] Render(int w, int h, int stride, int seed, bool lockScreen)
    {
        // Nord palette: polar night base, frost and aurora glows. Kept restrained so the
        // image stays dark and desktop icons remain readable.
        var glows = new[]
        {
            new Glow(0.20, 0.80, 0.17, 1.7, 0.50, 0x5E81AC),
            new Glow(0.76, 0.20, 0.12, 1.5, 0.30, 0x88C0D0),
            new Glow(0.92, 0.90, 0.10, 1.3, 0.28, 0xB48EAD),
            new Glow(0.03, 0.10, 0.09, 1.2, 0.20, 0x8FBCBB),
            new Glow(0.55, 1.10, 0.20, 2.2, 0.16, 0xA3BE8C),
        };

        var buf = new byte[stride * h];
        var rng = new Random(seed);
        double aspect = (double)h / w;
        double dim = lockScreen ? 0.62 : 1.0;

        for (int y = 0; y < h; y++)
        {
            double fy = (double)y / h;
            int row = y * stride;
            for (int x = 0; x < w; x++)
            {
                double fx = (double)x / w;

                // Base gradient, top #1B1F27 to bottom #2E3440 (Nord polar night).
                double t = fx * 0.25 + fy * 0.75;
                double r = Lerp(0x1B, 0x2E, t);
                double g = Lerp(0x1F, 0x34, t);
                double b = Lerp(0x27, 0x40, t);

                // A thin aurora ribbon that drifts across the upper half.
                double centre = 0.42 + 0.06 * Math.Sin(fx * Math.PI * 2 * 1.15 + 0.6) + 0.025 * Math.Sin(fx * Math.PI * 2 * 3.1 + 2.0);
                double band = (fy - centre) / 0.045;
                double ribbon = Math.Exp(-band * band) * 0.22 * (0.55 + 0.45 * Math.Sin(fx * Math.PI * 2 * 0.8 + 1.0));
                r = Lerp(r, 0x88, ribbon); g = Lerp(g, 0xC0, ribbon); b = Lerp(b, 0xD0, ribbon);

                // Soft elliptical glows, measured in pixel space so they are not squashed.
                for (int i = 0; i < glows.Length; i++)
                {
                    double dx = (fx - glows[i].X) / glows[i].Stretch;
                    double dy = (fy - glows[i].Y) * aspect * glows[i].Stretch;
                    double weight = glows[i].Strength * Math.Exp(-(dx * dx + dy * dy) / (2 * glows[i].Sigma * glows[i].Sigma));
                    r = Lerp(r, glows[i].R, weight); g = Lerp(g, glows[i].G, weight); b = Lerp(b, glows[i].B, weight);
                }

                if (lockScreen)
                {
                    double vx = fx - 0.5, vy = fy - 0.5;
                    double vignette = 1.0 - 0.45 * Math.Min(1.0, vx * vx * 1.6 + vy * vy * 2.2);
                    r *= dim * vignette; g *= dim * vignette; b *= dim * vignette;
                }

                // Dither to keep the gradients free of banding.
                double n = (rng.NextDouble() - 0.5) * 2.2;
                int idx = row + x * 3;
                buf[idx] = Clamp(b + n);
                buf[idx + 1] = Clamp(g + n);
                buf[idx + 2] = Clamp(r + n);
            }
        }
        return buf;
    }
}
'@

if (-not ('DotfilesWallpaper' -as [type])) {
    Add-Type -TypeDefinition $rendererSource
}
Add-Type -AssemblyName System.Drawing

if (-not $Width -or -not $Height) {
    $mode = & (Join-Path $PSScriptRoot 'Get-DisplayMode.ps1')
    if ($mode) {
        if (-not $Width) { $Width = $mode.Width }
        if (-not $Height) { $Height = $mode.Height }
    }
    else {
        if (-not $Width) { $Width = 2560 }
        if (-not $Height) { $Height = 1440 }
        Write-Warning "Could not read the primary display mode; rendering ${Width}x${Height}."
    }
}

$ditherSeed = $Seed

function Save-Render {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$LockScreen,
        [string]$PreviewPath
    )
    $stride = [int]((($Width * 3) + 3) -band -bnot 3)
    $bytes = [DotfilesWallpaper]::Render($Width, $Height, $stride, $ditherSeed, $LockScreen)

    $bmp = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $rect = [System.Drawing.Rectangle]::new(0, 0, $Width, $Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
        if ($data.Stride -ne $stride) { throw "Unexpected bitmap stride $($data.Stride), expected $stride." }
        [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $bytes.Length)
        $bmp.UnlockBits($data)
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)

        if ($PreviewPath) {
            $pw = [Math]::Min(1280, $Width)
            $ph = [int][Math]::Round($pw * $Height / $Width)
            $small = [System.Drawing.Bitmap]::new($pw, $ph)
            try {
                $gfx = [System.Drawing.Graphics]::FromImage($small)
                $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $gfx.DrawImage($bmp, 0, 0, $pw, $ph)
                $gfx.Dispose()
                $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
                $encParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
                $encParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]85)
                $small.Save($PreviewPath, $codec, $encParams)
            }
            finally { $small.Dispose() }
        }
    }
    finally { $bmp.Dispose() }
}

$desktopPath = Join-Path $OutputDirectory 'desktop.png'
$lockPath = Join-Path $OutputDirectory 'lockscreen.png'
$desktopPreview = if ($Preview) { Join-Path $OutputDirectory 'preview.jpg' } else { $null }
$lockPreview = if ($Preview) { Join-Path $OutputDirectory 'preview-lockscreen.jpg' } else { $null }

if ($PSCmdlet.ShouldProcess($OutputDirectory, "Render desktop.png and lockscreen.png at ${Width}x${Height}")) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Save-Render -Path $desktopPath -LockScreen $false -PreviewPath $desktopPreview
    Save-Render -Path $lockPath -LockScreen $true -PreviewPath $lockPreview
    $sw.Stop()

    # Lets install.ps1 skip the render when the generator, size and seed are unchanged.
    [ordered]@{
        Generator = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        Width     = $Width
        Height    = $Height
        Seed      = $Seed
        Rendered  = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'render.json') -Encoding UTF8
    Write-Host ("Rendered {0}x{1} in {2:n1} s:" -f $Width, $Height, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Get-ChildItem -LiteralPath $desktopPath, $lockPath | ForEach-Object { Write-Host ("  {0}  {1:n1} MB" -f $_.FullName, ($_.Length / 1MB)) }
    if ($Preview) { Write-Host "  $desktopPreview"; Write-Host "  $lockPreview" }
}
