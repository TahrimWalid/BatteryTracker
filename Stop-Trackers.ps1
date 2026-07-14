# Stop-Trackers.ps1 — finds and stops both BatteryLogger.ps1 and ProcessAudit.ps1.
#
# Uses Win32_Process.CommandLine to identify the right powershell.exe instances
# by the script path in their arguments — works regardless of window title or
# how many other PowerShell windows happen to be open.

$targets = [ordered]@{
    'BatteryLogger' = '*BatteryLogger.ps1*'
    'ProcessAudit'  = '*ProcessAudit.ps1*'
}

$stopped  = 0
$notFound = @()

foreach ($name in $targets.Keys) {
    $pattern = $targets[$name]
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
             Where-Object { $_.CommandLine -like $pattern }

    if ($procs) {
        foreach ($p in $procs) {
            try {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
                Write-Host "Stopped $name (PID $($p.ProcessId))." -ForegroundColor Green
                $stopped++
            } catch {
                Write-Host "Could not stop $name (PID $($p.ProcessId)): $_" -ForegroundColor Red
            }
        }
    } else {
        $notFound += $name
    }
}

if ($notFound.Count -gt 0) {
    Write-Host "Not running: $($notFound -join ', ')." -ForegroundColor DarkGray
}

Write-Host ""
if ($stopped -gt 0) {
    Write-Host "$stopped tracker(s) stopped." -ForegroundColor Cyan
} else {
    Write-Host "Nothing to stop." -ForegroundColor DarkGray
}
