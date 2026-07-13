if (-not ("WindowHelper" -as [type])) {
    # FIX: CharSet=Unicode added — without it, DllImport defaults to ANSI and
    # mangles any non-ASCII character in window titles (dashes, curly quotes,
    # non-Latin text all become "?"). This was visibly happening in your log.
    Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        using System.Text;
        public class WindowHelper {
            [DllImport("user32.dll", CharSet = CharSet.Unicode)]
            public static extern IntPtr GetForegroundWindow();
            [DllImport("user32.dll", CharSet = CharSet.Unicode)]
            public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
            [DllImport("user32.dll")]
            public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

            public static string GetActiveWindowTitle() {
                StringBuilder Buff = new StringBuilder(256);
                IntPtr handle = GetForegroundWindow();
                if (GetWindowText(handle, Buff, 256) > 0) return Buff.ToString();
                return "Unknown";
            }
            public static int GetActiveWindowPid() {
                IntPtr handle = GetForegroundWindow();
                uint pid;
                GetWindowThreadProcessId(handle, out pid);
                return (int)pid;
            }
        }
"@
}

$trackerDir = "$env:USERPROFILE\Desktop\BatteryTracker"
$logFile = "$trackerDir\BatteryLog.csv"
$jsFile = "$trackerDir\data.js"
$latestFile = "$trackerDir\latest.js"
$fullHistoryFile = "$trackerDir\full_history.js"

if (!(Test-Path $trackerDir)) { New-Item -ItemType Directory -Force -Path $trackerDir | Out-Null }

if (!(Test-Path $logFile)) {
    "Timestamp,IsOnBattery,BatteryPercent,SignedRate_mW,IntervalSeconds,ActiveWindow,ActiveProcess,TopProcessesByCpuDelta" | Out-File $logFile -Encoding utf8
}

# FIX: hard cap on in-memory/chart history. At 2s polling, 900 entries = 30 minutes
# of chart. Without this the JSON re-serialized every 2s grows forever and both
# the script and the dashboard slow down over a long session.
$maxHistoryEntries = 900
# Full session log for the "Load Full Session" button — same JS format as the
# live feed (no CSV round-trip, so no schema-drift risk), but written far less
# often since it's only needed on demand, not every 2s. Capped at 50,000
# entries (~27 hours at 2s polling) so it can't grow forever unbounded either
# — generous for any real single session, not infinite.
$maxFullHistoryEntries = 50000
$fullHistoryWriteEveryNTicks = 30  # ~once a minute at 2s polling
# FIX: previously wrote the ENTIRE capped array (up to 900 entries) to data.js
# on every single 2s tick — the dashboard then had to re-parse/execute that
# whole payload every poll even though only one entry had actually changed.
# Now: write just the newest entry (tiny) every tick, and only rewrite the
# full array periodically as a "keyframe" the dashboard can resync from if it
# missed anything (tab was backgrounded, a write got skipped, etc). Same
# pattern video codecs use — full frame occasionally, small deltas between.
$keyframeEveryNTicks = 15  # ~30s at 2s polling
$tickCount = 0

Write-Host "Hybrid Battery Logger & Dashboard Engine Started." -ForegroundColor Cyan
Write-Host "Data logging to: $logFile"
Write-Host "Live Dashboard updating at: $trackerDir\Dashboard.html"
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

$prevSnapshot = @{}
$prevTime = Get-Date
$isFirstRunAfterWake = $true
$sessionHistory = New-Object System.Collections.Generic.List[PSCustomObject]
$fullHistory = New-Object System.Collections.Generic.List[PSCustomObject]

while ($true) {
    try { $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop } catch { Start-Sleep -Seconds 2; continue }

    $currentProcs = Get-Process | Where-Object { $_.Name -ne "Idle" -and $_.Name -ne "System Process" -and $_.CPU -ne $null }
    $now = Get-Date
    $elapsed = ($now - $prevTime).TotalSeconds

    if ($elapsed -gt 25) { $isFirstRunAfterWake = $true }

    $isOnBattery = ($battery.BatteryStatus -eq 1)
    $pct = $battery.EstimatedChargeRemaining

    $wmiBattery = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue

    # FIX: keep charge/discharge distinct instead of one unsigned "rate" field.
    # Discharging = negative (losing energy). Charging = positive (gaining energy).
    # Plotting these as the same positive quantity (as before) makes a charging
    # period look like heavy "draw" on the chart.
    $signedRate = 0
    if ($wmiBattery) {
        if ($isOnBattery) { $signedRate = -1 * $wmiBattery.DischargeRate }
        else { $signedRate = $wmiBattery.ChargeRate }
    }

    if (-not $isFirstRunAfterWake) {
        $activeWindow = [WindowHelper]::GetActiveWindowTitle()
        $activePid    = [WindowHelper]::GetActiveWindowPid()
        $activeProcName = try { (Get-Process -Id $activePid -ErrorAction Stop).Name } catch { "Unknown" }

        $deltas = foreach ($p in $currentProcs) {
            $prevCpu = $prevSnapshot[$p.Id]
            if ($null -ne $prevCpu -and $elapsed -gt 0) {
                $deltaCpu = $p.CPU - $prevCpu
                if ($deltaCpu -gt 0) { [PSCustomObject]@{ Name = $p.Name; DeltaCpu = $deltaCpu } }
            }
        }

        $groupedProcs = $deltas | Group-Object Name | ForEach-Object {
            $totalDelta = ($_.Group | Measure-Object DeltaCpu -Sum).Sum
            [PSCustomObject]@{ Name = $_.Name; DeltaCpu = [math]::Round($totalDelta, 2) }
        }

        $topProcs = $groupedProcs | Sort-Object DeltaCpu -Descending | Select-Object -First 3
        $procString = ($topProcs | ForEach-Object { "$($_.Name) (+$($_.DeltaCpu)s)" }) -join " | "

        # FIX: date included, not just time-of-day. With full-session history
        # now covering up to ~27 hours, two entries at e.g. 14:22:03 from
        # different days would otherwise be indistinguishable.
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $roundedElapsed = [math]::Round($elapsed, 1)
        $safeWindow = $activeWindow -replace '"', '""'
        $safeProcString = $procString -replace '"', '""'

        $logLine = "$timestamp,$isOnBattery,$pct,$signedRate,$roundedElapsed,""$safeWindow"",""$activeProcName"",""$safeProcString"""

        try {
            $logLine | Out-File $logFile -Append -Encoding utf8 -ErrorAction Stop
        } catch {
            Write-Host "[$timestamp] CSV is locked. Data skipped for CSV, but Dashboard updated." -ForegroundColor Yellow
        }

        # FIX: entry carries the ACTUAL elapsed seconds for this sample instead of
        # the dashboard assuming a fixed 10s (or any fixed) tick. Your own log shows
        # real gaps vary between ~2s and 6s+ depending on system load.
        $entryObj = [PSCustomObject]@{
            Timestamp              = $timestamp
            IsOnBattery            = $isOnBattery
            BatteryPercent         = $pct
            SignedRate_mW          = $signedRate
            IntervalSeconds        = $roundedElapsed
            ActiveWindow           = $activeWindow   # raw text — JSON handles its own escaping
            ActiveProcess          = $activeProcName
            TopProcessesByCpuDelta = $procString
        }

        $sessionHistory.Add($entryObj)
        if ($sessionHistory.Count -gt $maxHistoryEntries) { $sessionHistory.RemoveAt(0) }

        $fullHistory.Add($entryObj)
        if ($fullHistory.Count -gt $maxFullHistoryEntries) { $fullHistory.RemoveAt(0) }

        $tickCount++

        # Tiny write, every tick: just the newest entry. This is what the
        # dashboard polls every 2s under normal operation — cheap to write,
        # cheap to parse.
        try {
            $latestJson = $entryObj | ConvertTo-Json -Compress
            "window.latestEntry = $latestJson;" | Out-File $latestFile -Encoding utf8 -ErrorAction Stop
        } catch {
            Write-Host "[$timestamp] Could not update latest.js (file locked)." -ForegroundColor Red
        }

        # Full keyframe, periodically: lets the dashboard do a complete resync
        # (first load, or catching up after a missed tick) without needing the
        # full array reparsed on every single poll like before.
        if ($tickCount % $keyframeEveryNTicks -eq 0 -or $tickCount -eq 1) {
            try {
                $json = @($sessionHistory) | ConvertTo-Json -Compress
                # window.batteryData (not const) so the dashboard can re-inject this file
                # repeatedly via a fresh <script> tag without a "already declared" error.
                "window.batteryData = $json;" | Out-File $jsFile -Encoding utf8 -ErrorAction Stop
            } catch {
                Write-Host "[$timestamp] Could not update data.js (file locked)." -ForegroundColor Red
            }
        }

        if ($tickCount % $fullHistoryWriteEveryNTicks -eq 0) {
            try {
                $fullJson = @($fullHistory) | ConvertTo-Json -Compress
                "window.fullBatteryData = $fullJson;" | Out-File $fullHistoryFile -Encoding utf8 -ErrorAction Stop
            } catch {
                Write-Host "[$timestamp] Could not update full_history.js (file locked)." -ForegroundColor Red
            }
        }

    } else {
        $isFirstRunAfterWake = $false
    }

    $prevSnapshot = @{}
    foreach ($p in $currentProcs) { $prevSnapshot[$p.Id] = $p.CPU }
    $prevTime = $now

    Start-Sleep -Seconds 2
}