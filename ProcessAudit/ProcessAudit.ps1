# ProcessAudit.ps1 — background process transparency tool (Level 2)
# Full process census, parent/child trees, digital signatures, loaded DLLs,
# network connections per process, windowless/long-lived flagging, autoruns
# enumeration, and sleep/idle gap markers.
#
# Scope note: this is a TRANSPARENCY tool, not anti-malware. It shows you
# what's running and its signature/network/lineage — it has no way to detect
# something actively hiding from these APIs (that's kernel-driver territory,
# a different engineering problem entirely, deliberately out of scope here).
#
# Everything here uses pure user-mode Windows APIs — no kernel driver, no ETW.
# ETW (ground-truth process birth/death with zero polling gaps) is Level 1,
# deferred — this script polls, so anything that spawns and fully exits
# between two ticks is invisible to it. Worth knowing, not fixed here.

if (-not ("WindowEnum" -as [type])) {
    Add-Type @"
        using System;
        using System.Collections.Generic;
        using System.Runtime.InteropServices;
        public class WindowEnum {
            public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
            [DllImport("user32.dll")]
            public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
            [DllImport("user32.dll")]
            public static extern bool IsWindowVisible(IntPtr hWnd);
            [DllImport("user32.dll")]
            public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

            // Every PID that owns at least one visible top-level window.
            // Anything NOT in this set has no UI — a background/service-style
            // process, which is the "windowless" signal the report uses.
            public static HashSet<uint> GetVisibleWindowPids() {
                var pids = new HashSet<uint>();
                EnumWindows((hWnd, lParam) => {
                    if (IsWindowVisible(hWnd)) {
                        uint pid;
                        GetWindowThreadProcessId(hWnd, out pid);
                        pids.Add(pid);
                    }
                    return true;
                }, IntPtr.Zero);
                return pids;
            }
        }
"@
}

$trackerDir = $PSScriptRoot
if (!(Test-Path $trackerDir)) { New-Item -ItemType Directory -Force -Path $trackerDir | Out-Null }

$liveFile      = "$trackerDir\processes_live.js"
$historyFile   = "$trackerDir\process_history.js"
$autorunsFile  = "$trackerDir\autoruns.js"
$gapEventsFile = "$trackerDir\gap_events.js"

$pollIntervalSeconds = 5
# Slower than the battery logger's 2s — a full process census with signature/
# network lookups is heavier per tick, and this data doesn't need sub-2s
# resolution the way battery draw does.

$maxHistoryEntries   = 720  # ~1 hour of snapshots at 5s polling
$autorunsEveryNTicks = 60   # ~5 min — autoruns almost never change tick-to-tick
$keyframeEveryNTicks = 12   # ~1 min — full-history resync cadence for the dashboard

# Cached per unique executable PATH, not per PID — a signature or DLL list is
# a property of the binary, not the running instance, so this avoids
# re-checking the same signature hundreds of times for e.g. every svchost.exe.
$signatureCache = @{}
$moduleCache    = @{}

$history   = New-Object System.Collections.Generic.List[PSCustomObject]
$gapEvents = New-Object System.Collections.Generic.List[PSCustomObject]

$tickCount = 0
$prevTime  = Get-Date

Write-Host "Process Audit started." -ForegroundColor Cyan
Write-Host "Writing to: $trackerDir"
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

function Get-SignatureStatus($path) {
    # FIX: previously "unknown" covered three different situations that need
    # to be told apart — a pseudo-process with no real file at all (expected,
    # not suspicious), a real file we couldn't read (likely needs admin —
    # this is almost certainly why core boot processes like csrss.exe were
    # showing up as "?" earlier), and a file that was actually checked but
    # came back ambiguous (genuinely worth a look).
    if ([string]::IsNullOrEmpty($path)) { return "nopath" }
    if ($signatureCache.ContainsKey($path)) { return $signatureCache[$path] }
    $status = "unknown"
    try {
        $sig = Get-AuthenticodeSignature -FilePath $path -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            $status = if ($sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'Microsoft') { "microsoft" } else { "signed" }
        } elseif ($sig.Status -eq 'NotSigned') {
            $status = "unsigned"
        } else {
            $status = "unknown"  # HashMismatch, NotTrusted, etc — genuinely ambiguous, worth a look
        }
    } catch {
        $status = "noaccess"  # couldn't even read the file — likely needs elevation
    }
    $signatureCache[$path] = $status
    return $status
}

function Get-ModuleList($procId, $path) {
    if ([string]::IsNullOrEmpty($path)) { return @() }
    if ($moduleCache.ContainsKey($path)) { return $moduleCache[$path] }
    $mods = @()
    try {
        $p = Get-Process -Id $procId -ErrorAction Stop
        $mods = @($p.Modules | Select-Object -First 15 -ExpandProperty ModuleName)
    } catch { }
    $moduleCache[$path] = $mods
    return $mods
}

while ($true) {
    $now = Get-Date
    $elapsed = ($now - $prevTime).TotalSeconds

    # Sleep/idle gap detection — mirrors the same pattern from the battery
    # logger: a large jump in wall-clock time between two consecutive ticks
    # means the machine was asleep/suspended in between (nothing can execute
    # during true suspend, including this script). Logged explicitly instead
    # of silently vanishing.
    if ($elapsed -gt ($pollIntervalSeconds * 3)) {
        $gapEvents.Add([PSCustomObject]@{
            GapStart        = $prevTime.ToString("yyyy-MM-dd HH:mm:ss")
            GapEnd          = $now.ToString("yyyy-MM-dd HH:mm:ss")
            DurationSeconds = [math]::Round($elapsed, 0)
        })
        try {
            $gapJson = @($gapEvents) | ConvertTo-Json -Compress
            "window.gapEvents = $gapJson;" | Out-File $gapEventsFile -Encoding utf8 -ErrorAction Stop
        } catch { }
    }
    $prevTime = $now

    $timestamp = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $tickCount++

    try { $visiblePids = [WindowEnum]::GetVisibleWindowPids() }
    catch { $visiblePids = New-Object 'System.Collections.Generic.HashSet[uint32]' }

    # One CIM call gets name, PID, PARENT PID, path, and exact start time —
    # far more reliable than guessing uptime by when we first happened to see it.
    $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue

    # Network connections mapped by owning PID — plain cmdlet, no ETW needed.
    $netByPid = @{}
    try {
        Get-NetTCPConnection -ErrorAction SilentlyContinue | ForEach-Object {
            $ownerPid = [int]$_.OwningProcess
            if (-not $netByPid.ContainsKey($ownerPid)) { $netByPid[$ownerPid] = @() }
            if ($netByPid[$ownerPid].Count -lt 5) {
                $netByPid[$ownerPid] += "$($_.RemoteAddress):$($_.RemotePort) [$($_.State)]"
            }
        }
    } catch { }

    $processSnapshot = foreach ($p in $procs) {
        $path = $p.ExecutablePath
        $startTime = $p.CreationDate
        $ageSeconds = if ($startTime) { [math]::Round(($now - $startTime).TotalSeconds, 0) } else { $null }
        $pidInt = [int]$p.ProcessId
        $sig = Get-SignatureStatus $path
        # Module list only for processes worth auditing — signed MS components
        # are not interesting and the lookup (even cached) adds per-process cost.
        $modules = if ($sig -eq 'unsigned' -or $sig -eq 'unknown') {
            Get-ModuleList $pidInt $path
        } else { @() }

        [PSCustomObject]@{
            Pid        = $pidInt
            ParentPid  = [int]$p.ParentProcessId
            Name       = $p.Name
            Path       = $path
            StartTime  = if ($startTime) { $startTime.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            AgeSeconds = $ageSeconds
            HasWindow  = $visiblePids.Contains([uint32]$pidInt)
            Signature  = $sig
            Modules    = $modules
            Network    = if ($netByPid.ContainsKey($pidInt)) { $netByPid[$pidInt] } else { @() }
        }
    }

    $snapshotObj = [PSCustomObject]@{ Timestamp = $timestamp; Processes = $processSnapshot }

    try {
        $liveJson = $snapshotObj | ConvertTo-Json -Compress -Depth 5
        "window.latestSnapshot = $liveJson;" | Out-File $liveFile -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Host "[$timestamp] Could not update processes_live.js (file locked)." -ForegroundColor Red
    }

    $history.Add($snapshotObj)
    if ($history.Count -gt $maxHistoryEntries) { $history.RemoveAt(0) }

    # Same keyframe-plus-delta pattern as the battery tool: full history only
    # rewritten periodically, not every tick — the live file above is what
    # carries the frequent updates.
    if ($tickCount % $keyframeEveryNTicks -eq 0 -or $tickCount -eq 1) {
        try {
            $histJson = @($history) | ConvertTo-Json -Compress -Depth 6
            "window.processHistory = $histJson;" | Out-File $historyFile -Encoding utf8 -ErrorAction Stop
        } catch {
            Write-Host "[$timestamp] Could not update process_history.js (file locked)." -ForegroundColor Red
        }
    }

    # Autoruns: Registry Run/RunOnce keys, Scheduled Tasks, Startup folder,
    # WMI permanent event subscriptions (a classic persistence-hiding spot).
    # Refreshed on a slow cadence — these almost never change tick-to-tick.
    if ($tickCount % $autorunsEveryNTicks -eq 0 -or $tickCount -eq 1) {
        $autoruns = @()

        foreach ($hive in @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
        )) {
            try {
                $entries = Get-ItemProperty -Path $hive -ErrorAction Stop
                $entries.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    $autoruns += [PSCustomObject]@{ Source = "Registry: $hive"; Name = $_.Name; Command = "$($_.Value)" }
                }
            } catch { }
        }

        try {
            Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' } | ForEach-Object {
                $actionCmd = ($_.Actions | ForEach-Object { $_.Execute }) -join '; '
                $autoruns += [PSCustomObject]@{ Source = "Scheduled Task"; Name = $_.TaskName; Command = $actionCmd }
            }
        } catch { }

        foreach ($folder in @(
            "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
        )) {
            if (Test-Path $folder) {
                Get-ChildItem -Path $folder -ErrorAction SilentlyContinue | ForEach-Object {
                    $autoruns += [PSCustomObject]@{ Source = "Startup Folder"; Name = $_.Name; Command = $_.FullName }
                }
            }
        }

        try {
            Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -ErrorAction Stop | ForEach-Object {
                $autoruns += [PSCustomObject]@{ Source = "WMI Event Subscription"; Name = $_.Name; Command = $_.CommandLineTemplate }
            }
        } catch { }

        try {
            $autorunsJson = @($autoruns) | ConvertTo-Json -Compress -Depth 4
            "window.autorunsData = $autorunsJson;" | Out-File $autorunsFile -Encoding utf8 -ErrorAction Stop
        } catch {
            Write-Host "[$timestamp] Could not update autoruns.js (file locked)." -ForegroundColor Red
        }
    }

    Start-Sleep -Seconds $pollIntervalSeconds
}