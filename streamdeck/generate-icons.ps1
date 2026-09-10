<#
.SYNOPSIS
    Generates the PNG icons required by the Stream Deck plugin manifest.
.DESCRIPTION
    Icons are generated rather than committed so there are no binary assets in the repo.
    Stream Deck expects each icon at 1x and 2x, with the 2x file suffixed "@2x".
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$imgs = Join-Path $PSScriptRoot 'com.ryanlowdermilk.audezemicmute.sdPlugin\imgs'
New-Item -ItemType Directory -Force -Path $imgs | Out-Null

function New-DotIcon {
    param(
        [string]$Path,
        [int]$Size,
        [System.Drawing.Color]$Color,
        [switch]$FilledBackground
    )

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        if ($FilledBackground) {
            $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 20, 21, 26))
            $g.FillRectangle($bg, 0, 0, $Size, $Size)
            $bg.Dispose()
        }

        $inset = [Math]::Max(2, [int]($Size * 0.18))
        $rect = New-Object System.Drawing.Rectangle($inset, $inset, ($Size - $inset * 2), ($Size - $inset * 2))

        $brush = New-Object System.Drawing.SolidBrush $Color
        $g.FillEllipse($brush, $rect)
        $brush.Dispose()

        $penWidth = [Math]::Max(1.0, $Size * 0.06)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(220, 255, 255, 255)), $penWidth
        $g.DrawEllipse($pen, $rect)
        $pen.Dispose()

        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $g.Dispose()
        $bmp.Dispose()
    }
}

$green = [System.Drawing.Color]::FromArgb(255, 46, 204, 96)

# name, 1x size
$icons = @(
    @{ Name = 'plugin';   Size = 72; Filled = $true  },
    @{ Name = 'category'; Size = 28; Filled = $false },
    @{ Name = 'action';   Size = 20; Filled = $false },
    @{ Name = 'key';      Size = 72; Filled = $true  }
)

foreach ($icon in $icons) {
    $one = Join-Path $imgs ($icon.Name + '.png')
    $two = Join-Path $imgs ($icon.Name + '@2x.png')

    if ($icon.Filled) {
        New-DotIcon -Path $one -Size $icon.Size -Color $green -FilledBackground
        New-DotIcon -Path $two -Size ($icon.Size * 2) -Color $green -FilledBackground
    }
    else {
        New-DotIcon -Path $one -Size $icon.Size -Color $green
        New-DotIcon -Path $two -Size ($icon.Size * 2) -Color $green
    }

    Write-Host ("Wrote {0} and {1}" -f (Split-Path $one -Leaf), (Split-Path $two -Leaf))
}
