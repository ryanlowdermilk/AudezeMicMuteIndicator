<#
.SYNOPSIS
    Installs the Stream Deck plugin and restarts the Stream Deck application.
.DESCRIPTION
    Copies the .sdPlugin folder into %APPDATA%\Elgato\StreamDeck\Plugins. Stream Deck only scans
    for plugins at startup, so it has to be restarted for the plugin to appear.

    Stream Deck will be closed and relaunched. Any Stream Deck action currently running will stop.
#>

$ErrorActionPreference = 'Stop'

$pluginName = 'com.ryanlowdermilk.audezemicmute.sdPlugin'
$source = Join-Path $PSScriptRoot $pluginName
$target = Join-Path $env:APPDATA "Elgato\StreamDeck\Plugins\$pluginName"

if (-not (Test-Path (Join-Path $source 'AudezeMicMuteStreamDeck.exe'))) {
    throw "Plugin not built. Run .\build.ps1 first."
}

$streamDeckExe = Join-Path $env:ProgramFiles 'Elgato\StreamDeck\StreamDeck.exe'
if (-not (Test-Path $streamDeckExe)) { throw "Stream Deck not found at $streamDeckExe" }

$stopped = $false
$running = Get-Process StreamDeck -ErrorAction SilentlyContinue
if ($running) {
    Write-Host 'Closing Stream Deck...' -ForegroundColor Yellow
    foreach ($p in $running) {
        try {
            $null = $p.CloseMainWindow()
            if ($p.WaitForExit(5000)) { $stopped = $true }
        }
        catch { }
    }
    if (-not $stopped) {
        try {
            $running | Stop-Process -ErrorAction Stop
            Start-Sleep -Seconds 2
            $stopped = $true
        }
        catch {
            # Stream Deck is running elevated; we cannot stop it without a UAC prompt.
            $stopped = $false
        }
    }
}
else { $stopped = $true }

Get-Process AudezeMicMuteStreamDeck -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

if (Test-Path $target) { Remove-Item $target -Recurse -Force }
Copy-Item $source $target -Recurse -Force
Write-Host "Installed to $target" -ForegroundColor Green

if ($stopped) {
    Write-Host 'Starting Stream Deck...' -ForegroundColor Yellow
    Start-Process $streamDeckExe
    Start-Sleep -Seconds 5
    $sd = Get-Process StreamDeck -ErrorAction SilentlyContinue
    if ($sd) { Write-Host "Stream Deck running (PID $($sd.Id))" -ForegroundColor Green }
    else { Write-Warning 'Stream Deck did not start. Launch it manually.' }
}
else {
    Write-Host ''
    Write-Warning 'Stream Deck is running elevated and could not be closed automatically.'
    Write-Host 'The plugin files are installed. To load it, restart Stream Deck yourself:' -ForegroundColor Cyan
    Write-Host '  right-click the Stream Deck tray icon -> Quit, then start it again.' -ForegroundColor Cyan
}
