<#
.SYNOPSIS
    Builds MicMuteIndicator.exe using the C# compiler that ships with Windows.
.DESCRIPTION
    Targets .NET Framework 4.8, which is built into Windows 11, so the result is a single
    self-contained .exe with no runtime to install.
#>

$ErrorActionPreference = 'Stop'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    throw "csc.exe not found at $csc"
}

$src = Join-Path $PSScriptRoot 'src\MicMuteIndicator.cs'
$out = Join-Path $PSScriptRoot 'MicMuteIndicator.exe'

& $csc /nologo /target:winexe /optimize+ /platform:anycpu `
    /out:$out `
    /reference:System.dll `
    /reference:System.Drawing.dll `
    /reference:System.Windows.Forms.dll `
    $src

if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

$size = [math]::Round((Get-Item $out).Length / 1KB, 1)
Write-Host "Built $out ($size KB)" -ForegroundColor Green
