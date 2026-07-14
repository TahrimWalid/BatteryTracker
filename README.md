<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/battery-dark.svg">
  <img src="assets/battery-light.svg" width="72" height="72" alt="">
</picture>

<h1>BatteryTracker</h1>

<p>Windows battery telemetry and process transparency — live discharge analysis and full process audit in a self-contained terminal dashboard</p>

</div>

---

## Overview

BatteryTracker is two tools in one browser tab:

**Battery Logger** polls your laptop every 2 seconds, recording signed power rate from WMI, battery percentage, active foreground window, and highest-CPU-delta processes. It also captures CPU temperature, active power plan, and battery health (design vs. full-charge capacity). All of it feeds a live Chart.js dashboard with no page reload.

**Process Auditor** runs a full process census every 5 seconds: executable signatures, parent/child lineage, network connections per process, loaded DLLs for flagged processes, autorun enumeration across four persistence vectors, and sleep/wake gap detection. Results appear in a second dashboard tab alongside a live watchlist, new-process log, and connection expand-on-click.

No external services, no telemetry, no internet connection required. Chart.js and JetBrains Mono are bundled locally.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 or later (included with Windows)
- Any modern browser to open the dashboard

The `BatteryTracker` folder must sit at `%USERPROFILE%\Desktop\BatteryTracker`. Paths are hardcoded to that location.

---

## Quick Start

**1. Place the folder on your Desktop:**

```
%USERPROFILE%\Desktop\BatteryTracker\
```

**2. Start both trackers with a single script:**

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
& "$env:USERPROFILE\Desktop\BatteryTracker\Launch-Trackers.ps1"
```

Each tracker opens in its own independent PowerShell window. The launcher window can be closed immediately — it is not keeping them alive.

**3. Open `Dashboard.html` in a browser.**

The **LIVE** badge in the top-right confirms data is flowing. Navigate between the **[~] BATTERY** and **[#] PROCESSES** tabs using the tab bar or keys `1` / `2`.

**4. To stop both trackers:**

```powershell
& "$env:USERPROFILE\Desktop\BatteryTracker\Stop-Trackers.ps1"
```

This identifies each tracker by its command-line arguments, not by window title, so it works correctly even if multiple PowerShell windows are open.

---

## Architecture

```
BatteryLogger.ps1
  every 2 s   ──► latest.js           one entry — the cheap live delta
  every ~30 s ──► data.js             rolling 30-min window (900 entries)
  every ~60 s ──► full_history.js     full session up to ~27 h, on-demand only
  at startup  ──► battery_health.js   design/full capacity, health %, cycle count
              ──► BatteryLog.csv      append-only persistent log

ProcessAudit\ProcessAudit.ps1
  every 5 s   ──► processes_live.js   full process census snapshot
  every ~60 s ──► process_history.js  rolling 1-h history of snapshots
  every ~5 min──► autoruns.js         Registry Run keys, Scheduled Tasks, Startup, WMI subs
  on detection──► gap_events.js       sleep/wake gap log
  on detection──► parent_alerts.js    anomalous parent→child process pairs
  on detection──► wake_alerts.js      non-MS processes present after sleep that weren't before
  on detection──► autorun_alerts.js   autorun entries added since the last scan
  on detection──► network_alerts.js   first-seen remote IP per process (after 60s warm-up)

Dashboard.html
  Battery tab  — injects latest.js each tick; resyncs from data.js every ~40 s
  Processes tab — injects processes_live.js every 5 s; lazy-loaded on first visit
```

The dashboard never touches the internet. All data exchange is local file reads via `<script>` tag injection, which works in any browser without a local server.

---

## Dashboard — Battery Tab

### Status Badge

| State | Meaning |
|---|---|
| **LIVE** | Data received within the last 15 seconds |
| **OFFLINE** | Logger stopped or data file is stale |
| **FROZEN** | Dashboard refresh paused; logger still writing in the background |
| **FULL SESSION LOADED** | Viewing `full_history.js`; live updates suspended |

### Stat Cards

| Label | Value |
|---|---|
| `rate.current` | Instantaneous power draw or charge rate in watts |
| `rate.avg` | Mean rate across the visible window |
| `rate.peak` | Peak absolute power rate in the current view — amber above 15 W, red above 30 W |
| `batt.level` | Current battery percentage (always from the latest sample, ignores filter) |
| `session.len` | Total elapsed time of the filtered data |
| `temp.cpu` | Peak thermal zone temperature in °C — amber above 75°C, red above 90°C. Hidden if the logger cannot read thermal data on this machine. |
| `batt.health` | Full-charge capacity as a percentage of design capacity — amber below 80%, red below 60%. Sub-label shows current Wh and cycle count. Hidden if WMI cannot return capacity data. |
| `eta.empty` | Estimated time to empty at current pace — shown only while discharging with at least 3 discharge samples |

### Chart

A dual-axis line chart plots power rate (left axis, watts) and battery percentage (right axis) over time. The live view shows the most recent 150 samples (~5 minutes at 2 s polling). The rate line is **green** while discharging and **amber** while charging. Vertical dashed markers appear at every plug/unplug transition; the peak discharge point is annotated inline.

Battery percentage uses an adaptive Y-axis: when the visible window spans less than 2 percentage points the axis zooms in so any slope is visible rather than appearing flat.

### Process Leaderboard

The top six processes by foreground active time are listed with a proportional bar and an estimated share of total charge drained, computed from each process's proportion of discharge energy consumed (`discharge rate × elapsed seconds`).

| Category | Recognized processes |
|---|---|
| Browser | chrome, msedge, firefox, brave, opera |
| Dev Tools | Code, devenv, powershell, pwsh, WindowsTerminal, cmd |
| Communication | Discord, WhatsApp, Zoom, Teams, Slack, Skype |
| System | explorer, svchost, MsMpEng, dwm, and others |
| Other | Everything not matched above |

### Controls

| Button | Key | Action |
|---|---|---|
| **[~] BATTERY** | `1` | Switch to battery tab |
| **[#] PROCESSES** | `2` | Switch to processes tab |
| **FREEZE** | — | Pause dashboard refresh. A scroll slider appears to pan through the full 30-min rolling window. |
| **LOAD FULL SESSION** | — | Inject `full_history.js` for a scrollable view of the entire session (up to ~27 hours). |
| **RETURN TO LIVE** | — | Exit full-session mode and resume live updates. |
| **[v] EXPORT CSV** | — | Download the current data (live buffer or full session) as a properly-quoted CSV file. |
| **[!] ALERTS** | — | Request browser notification permission. Fires at ≤20% and ≤10% battery (resets on plug-in) and for each new unsigned process detected on the Processes tab. |

### Filters

| Button | Key | Effect |
|---|---|---|
| ALL | `a` | All samples |
| ON BATTERY | `b` | Discharge samples only |
| CHARGING | `c` | Charge samples only |

Filters apply simultaneously to the chart, all stat cards, the leaderboard, and session duration. The `batt.level` and `eta.empty` cards always use the latest absolute sample regardless of filter.

### Power Plan

The power plan active at the time of each sample (`Balanced`, `High Performance`, etc.) is appended to the `rate.current` sub-label as `discharging · Balanced`. It updates whenever the plan changes, reflecting real-time power management state.

---

## Dashboard — Processes Tab

### Stat Cards

| Label | Value |
|---|---|
| `total.procs` | Total running processes at the last snapshot |
| `unsigned` | Processes whose executable is not Authenticode-signed |
| `windowless` | Processes with no visible top-level window |
| `oldest.proc` | Age of the longest-running process |
| `net.active` | Processes with at least one active TCP connection |
| `autoruns` | Total entries across all monitored persistence locations |

### Process Table

All running processes sorted by age (oldest first). Columns: **Process · PID · Parent · Signed · Age · Window · Network · Path**.

- **Search**: Type in the filter box above the table to narrow by process name or path in real time.
- **Network expand**: Click any underlined network cell to expand an inline row showing each connection's remote address, port, and state. Click again to collapse. Only one row expands at a time.
- **Path**: Truncated with `…` and full path visible on hover.

The table DOM is diffed by PID on every 5-second poll — only changed cells are written, no full rebuild.

### Watchlist

Processes flagged for review, filtered to reduce noise:

- Unsigned or ambiguous-signature executables (excluding pathless pseudo-processes and elevation-denied checks)
- Third-party signed executables that are windowless and have been running over an hour

Each entry shows name, PID, flag reasons, executable path, and — for unsigned/unknown processes — the first five loaded DLL names from the module cache. Signed Microsoft components are excluded entirely.

### Autoruns

Enumerated across four persistence vectors, refreshed every ~5 minutes:

| Source | What is checked |
|---|---|
| Registry Run/RunOnce | `HKLM` and `HKCU` under `CurrentVersion\Run` and `RunOnce` |
| Scheduled Tasks | All non-disabled tasks |
| Startup Folders | Per-user and all-users startup folders |
| WMI Event Subscriptions | `CommandLineEventConsumer` — a classic persistence hiding spot |

### Sleep Gaps Log

When the gap between two consecutive ticks exceeds 3× the poll interval, the auditor logs it as a sleep/suspend event with start time, end time, and duration. Mirrors the same detection logic in the battery logger.

### New Processes Log

Any process that appears in a snapshot but was absent from the previous one is logged here with a timestamp, name, PID, and signature badge — provided it is not a Microsoft-signed or pathless pseudo-process.

On first load, `process_history.js` (the last ~60 minutes of snapshots) is loaded to establish a historical baseline. This means the new-process log catches processes that started before the dashboard was opened, not only processes that started while it was open.

---

## Battery Logger

### Power Rate

Power rate is read from `BatteryStatus` in the `root\wmi` WMI namespace. Discharge rates are stored as **negative** values; charge rates as **positive**. The dashboard plots the magnitude and uses line color to indicate direction, so higher on the chart always means more power activity regardless of direction.

### Process Tracking

Each tick computes per-process CPU deltas by comparing the current cumulative `CPU` value against the previous snapshot. This identifies processes active during the interval, not merely those with the highest lifetime CPU. The top three by delta are written to the log as `TopProcessesByCpuDelta`.

### Window Title Capture

Active window title is read via `GetForegroundWindow` / `GetWindowText` from `user32.dll`. The P/Invoke declaration sets `CharSet = CharSet.Unicode` to correctly handle non-ASCII characters that would otherwise be corrupted to `?`.

### Battery Health

At startup (and hourly thereafter) the logger queries `BatteryStaticData` and `BatteryFullChargedCapacity` from `root\wmi` to compute:

```
health % = (FullChargedCapacity / DesignedCapacity) × 100
```

Result, design capacity in mWh, current full capacity in mWh, and cycle count are written to `battery_health.js`. The dashboard loads this once on startup and displays the `batt.health` stat card when data is available.

### CPU Temperature

Each tick queries `MSAcpi_ThermalZoneTemperature` from `root\wmi`, converts from tenths-of-Kelvin to °C, and reports the peak zone. Stored as `CpuTemp_C` on every log entry. Silently skipped if the class is unavailable (requires no admin on most OEM laptops but may be restricted on some hardware).

### Power Plan

`powercfg /getactivescheme` is called once at startup and cached, refreshing every ~2 minutes. The active scheme name is stored as `PowerPlan` on every log entry and shown in the dashboard alongside the charge state.

### Polling and Write Pattern

The logger uses a keyframe-plus-delta pattern to keep writes cheap:

| Write | Frequency | Content |
|---|---|---|
| `latest.js` | Every tick (~2 s) | One entry — the current state only |
| `data.js` | Every 15 ticks (~30 s) | Full rolling 900-entry window |
| `full_history.js` | Every 30 ticks (~60 s) | Full session up to 50,000 entries |
| `battery_health.js` | Startup + every 1800 ticks (~1 h) | Capacity and health data |
| `BatteryLog.csv` | Every tick | Append-only persistent log |

The dashboard polls `latest.js` on most ticks and resyncs from `data.js` roughly every 40 seconds, matching the keyframe cadence without tight coupling.

### Memory Bounds

| Buffer | Limit | Approx. duration at 2 s polling |
|---|---|---|
| Live chart window (`data.js`) | 900 entries | ~30 minutes |
| Full session history (`full_history.js`) | 50,000 entries | ~27 hours |

### Edge Cases

**Wake from sleep.** If more than 25 seconds elapse between ticks, the logger skips that sample and resets the CPU delta baseline. The elapsed time field would otherwise record the full suspension duration as a single polling interval, skewing energy calculations.

**Locked CSV.** If another process holds `BatteryLog.csv` open, the logger skips the CSV write for that tick but continues updating all `.js` files. A warning is printed to the console.

---

## Process Auditor

### Process Census

Each tick calls `Get-CimInstance Win32_Process` to enumerate all running processes with name, PID, parent PID, executable path, and exact start time (not a running estimate). `GetVisibleWindowPids` enumerates all visible top-level windows via `EnumWindows` to build a PID → has-window map.

### Signature Verification

`Get-AuthenticodeSignature` is called once per unique executable path and cached for the session. Results are classified as:

| Status | Meaning |
|---|---|
| `microsoft` | Valid signature from Microsoft — excluded from watchlist |
| `signed` | Valid third-party Authenticode signature |
| `unsigned` | File is not signed |
| `unknown` | Signed but status is ambiguous (HashMismatch, NotTrusted, etc.) — worth reviewing |
| `noaccess` | File could not be read — likely requires elevation |
| `nopath` | No executable file on disk (pseudo-process, kernel thread) |

### Module Tracking

For `unsigned` and `unknown` processes, `Get-Process.Modules` is called once per unique executable path and cached. Up to 15 loaded DLL names are stored. Results appear in the watchlist panel in the dashboard.

### Network Connections

`Get-NetTCPConnection` maps active connections to owning PIDs. Up to 5 connections per process are stored as `RemoteAddress:Port [State]` strings. The dashboard table shows a connection count; clicking the cell expands an inline row with each connection string.

### Polling and Write Pattern

| Write | Frequency | Content |
|---|---|---|
| `processes_live.js` | Every tick (~5 s) | Full current process snapshot |
| `process_history.js` | Every 12 ticks (~60 s) | Rolling window of 720 snapshots (~1 hour) |
| `autoruns.js` | Every 60 ticks (~5 min) | All persistence enumeration results |
| `gap_events.js` | On detection | Cumulative sleep/suspend gap log |

### Security Alert Panels

Three alert panels are shown at the top of the lower grid. They appear empty until an event is detected, at which point the border turns red and the panel fills. Browser notifications fire if permission was granted via the `[!] ALERTS` button.

**parent_alerts.log — process lineage anomalies**

Each new process is checked against a list of suspicious parent→child pairs. Examples: Word/Excel spawning PowerShell (macro execution path), browsers spawning PowerShell, WScript/CScript/MSHTA spawning PowerShell (staged execution), lsass spawning anything (credential dumping indicator). Alerts accumulate for the session and deduplicate by PID — the same child is only reported once even if it stays alive across multiple scans.

**wake_alerts.log — post-sleep new processes**

When the poll gap indicates a sleep/resume cycle, the process snapshot taken just before sleep is compared against the current snapshot. Any non-Microsoft-signed process present after waking that was absent before is logged. This catches software that uses the suspend window to install or launch silently.

**autorun_alerts.log — persistence changes**

Every ~5-minute autorun scan is diffed against the previous scan. New entries — in Registry Run/RunOnce, Scheduled Tasks, Startup folders, or WMI subscriptions — are flagged immediately. Benign software installs will trigger this; that is expected. The value is in knowing exactly when and what changed, so installs you recognize can be dismissed and surprises stand out.

**network_alerts.log — new remote destinations per process**

The first 60 seconds of the auditor's run is a silent warm-up: every Established TCP connection is added to a per-process IP baseline with no alerts. After warm-up, any first-seen remote IP for a known process is logged. Chrome connecting to a new Google IP address = expected and will populate the baseline fast. Chrome later connecting to `185.x.x.x:4444` = flagged immediately. Each destination is only flagged once — subsequent connections to the same IP are silent. No new WMI calls: this is pure analysis of the TCP connection data already collected every tick.

### Scope Note

This is a transparency tool, not anti-malware. It uses user-mode Windows APIs only. A process that actively hides from these APIs (rootkit-level kernel driver hooking) is outside scope. Polling also means a process that spawns and fully exits within one 5-second tick is invisible — though in practice such processes almost always leave a downstream trace that this tool does catch: a new autorun entry, a persistent child process, or a new network destination.

If you need zero-second process visibility specifically, run [Sysmon](https://learn.microsoft.com/en-us/sysinternals/downloads/sysmon) (free, Sysinternals/Microsoft) alongside this tool. It uses ETW at the kernel level to log every process creation (Event ID 1, with full command line and parent chain) to the Windows Event Log — exactly the blind spot that polling cannot close. The two tools complement rather than overlap.

---

## File Layout

```
BatteryTracker/
├── BatteryLogger.ps1                           battery data engine
├── ProcessAudit/
│   └── ProcessAudit.ps1                        process audit engine
├── Launch-Trackers.ps1                         starts both engines in separate windows
├── Stop-Trackers.ps1                           stops both engines by command-line match
├── Dashboard.html                              single-file browser dashboard
├── chart.umd.min.js                            Chart.js (bundled, no CDN)
├── fonts/
│   ├── jetbrains-mono-latin-400-normal.woff2
│   ├── jetbrains-mono-latin-500-normal.woff2
│   └── jetbrains-mono-latin-700-normal.woff2
│
│   — runtime files, created automatically, gitignored —
├── BatteryLog.csv
├── latest.js
├── data.js
├── full_history.js
├── battery_health.js
└── ProcessAudit/
    ├── processes_live.js
    ├── process_history.js
    ├── autoruns.js
    ├── gap_events.js
    ├── parent_alerts.js
    ├── wake_alerts.js
    ├── autorun_alerts.js
    └── network_alerts.js
```

Runtime files are created on the first run and are excluded from version control via `.gitignore`.

---

## Notes

- `data.js` assigns to `window.batteryData` (not `const`/`let`) so the dashboard can safely re-inject it via a fresh `<script>` tag without a redeclaration error.
- The status badge DOM is only written when its state changes — not on every 2-second tick. Replacing `innerHTML` unconditionally would restart the CSS pulse animation, producing a visible flicker.
- The process table and battery leaderboard both use keyed DOM diffing: rows are matched by PID or process name and patched in place. Neither rebuilds `innerHTML` on every poll.
- The dashboard is fully offline-capable. All CSS, fonts, and Chart.js are bundled. No requests ever leave the machine.
- To relocate the folder, update `$trackerDir` near the top of `BatteryLogger.ps1`. All derived paths are computed from that variable. `ProcessAudit.ps1` uses `$PSScriptRoot` and does not need to be changed.
