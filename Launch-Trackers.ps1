# Launch-Trackers.ps1 — starts both BatteryLogger.ps1 and ProcessAudit.ps1
# at once, each in its own independent PowerShell window.
#
# Deliberately NOT using background jobs (Start-Job): jobs are tied to this
# launcher's session, so closing this window would kill both trackers along
# with it. Start-Process instead launches two fully separate processes that
# keep running even after this window closes — same as if you'd started each
# one manually in its own console, just done in one step.

$batteryScript = "$env:USERPROFILE\Desktop\BatteryTracker\BatteryLogger.ps1"
$processScript = "$env:USERPROFILE\Desktop\BatteryTracker\ProcessAudit\ProcessAudit.ps1"

$missing = @()
if (!(Test-Path $batteryScript)) { $missing += $batteryScript }
if (!(Test-Path $processScript)) { $missing += $processScript }

if ($missing.Count -gt 0) {
    Write-Host "Can't find:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "Expected BatteryLogger.ps1 in Desktop\BatteryTracker and ProcessAudit.ps1 in Desktop\BatteryTracker\ProcessAudit." -ForegroundColor Yellow
    exit 1
}

Write-Host "Starting BatteryLogger.ps1 in its own window..." -ForegroundColor Cyan
Start-Process powershell.exe -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$batteryScript`""

Start-Sleep -Seconds 1

Write-Host "Starting ProcessAudit.ps1 in its own window..." -ForegroundColor Cyan
Start-Process powershell.exe -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$processScript`""

Write-Host ""
Write-Host "Both trackers are running in their own windows now." -ForegroundColor Green
Write-Host "This launcher window can be closed safely -- it isn't keeping them alive." -ForegroundColor DarkGray