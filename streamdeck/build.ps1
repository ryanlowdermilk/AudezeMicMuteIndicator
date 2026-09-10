<#
.SYNOPSIS
    Builds the Stream Deck plugin executable and generates its icons.
.DESCRIPTION
    The plugin compiles the tray app's source alongside its own so both share one copy of the
    detection logic in MicMonitor. Both files declare a Main, so /main selects the entry point.
#>

$ErrorActionPreference = 'Stop'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }

& (Join-Path $PSScriptRoot 'generate-icons.ps1')

$pluginDir = Join-Path $PSScriptRoot 'com.ryanlowdermilk.audezemicmute.sdPlugin'
$out = Join-Path $pluginDir 'AudezeMicMuteStreamDeck.exe'

$shared = Join-Path $PSScriptRoot '..\src\MicMuteIndicator.cs'
$plugin = Join-Path $PSScriptRoot 'src\StreamDeckPlugin.cs'

& $csc /nologo /target:winexe /optimize+ /platform:anycpu `
    /main:MicMuteIndicator.StreamDeck.Plugin `
    /out:$out `
    /reference:System.dll `
    /reference:System.Drawing.dll `
    /reference:System.Windows.Forms.dll `
    /reference:System.Web.Extensions.dll `
    $shared $plugin

if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

$size = [math]::Round((Get-Item $out).Length / 1KB, 1)
Write-Host "Built $out ($size KB)" -ForegroundColor Green
