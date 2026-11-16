# ssd-write-monitor

English | [繁體中文](README.zh-TW.md)

Windows tooling that measures **what is actually written to each physical disk**, attributes
writes to processes via ETW, and reports which ones wear out your SSD — so you can move the
noisy ones off `C:`.

---

## Why this exists

Windows tells you how full `C:` is, but not what is *wearing it out*. Task Manager shows
per-process I/O numbers that include cache hits, pipes and sockets, so they overstate real
writes by an order of magnitude (measured: 5.83 GB of "process I/O" for one hour, while the
disk actually received 191.8 MB). SMART gives you a lifetime total and nothing else.

This project answers three questions with data from the only counter that reflects physical
writes — `Win32_PerfRawData_PerfDisk_PhysicalDisk`:

1. How many bytes per hour/day does each **physical disk** actually receive?
2. **Which process and which file** produced them (ETW Kernel-File)?
3. What is the trend, and which writes are worth relocating to another drive?

## What it does

| Capability | What you get |
|---|---|
| **Sampling** | One sample per minute per physical disk, from cumulative performance counters (byte-accurate deltas) |
| **Attribution** | ETW Kernel-File events → `data\attrib\<date>.csv` (pid, process, volume, path, bytes, ops) |
| **Hourly reports** | `reports\<yyyy-MM-dd>.md` — per-hour writes, top processes, per-volume breakdown, coverage |
| **Daily comparison** | `reports\daily.md` — per-day writes for `C:`/`D:`, plus a **SMART reconciliation** column that flags days where physical writes and SMART HostWrites disagree |
| **Web dashboard** | `http://localhost:8737/` — live rate, today's totals, 24-hour trend, per-process ranking (15 s refresh, no framework) |
| **Tray icon** | Shows current rate and starts the dashboard |
| **Diagnostics** | `status.ps1` (one-shot health), `clean-attrib.ps1` (drop impossible attributions and reconcile per disk), `check-scripts.ps1` (BOM + syntax check for every `.ps1`) |

## How it works (30 seconds)

- **Measure:** the raw `PhysicalDisk` counters are the only numbers that mean "bytes that
  reached the device". `LogicalDisk` includes cache hits and delayed write-back; per-process
  I/O counters include pipes, sockets and cache — both are far off (see the table in the
  Chinese README for the measured comparison).
- **Attribute:** a small C# collector opens an ETW kernel session (`Kernel-File`) and writes
  pid × file × bytes rows. This is why it needs administrator rights.
- **Reconcile:** write counters reset on reboot and disk numbers can swap after a reboot, so
  the aggregators split series at counter resets and group by volume label rather than by
  device index.

## Requirements

- Windows 10 or Windows 11 (x64).
- PowerShell 5.1 (built in) — the scripts also run on PowerShell 7.
- Administrator rights **only** for the ETW collector (`install-collector.ps1`,
  `deploy-collector.ps1`). Sampling, reports and the dashboard run as a normal user.
- Optional: [CrystalDiskInfo](https://crystalmark.info/en/software/crystaldiskinfo/) writing
  `HostWrites.csv` — adds multi-year SMART history to the daily report.
- .NET Framework 4.x (present on Windows 10/11). The collector is compiled with the built-in
  `csc.exe` (`src\cwatch\build.ps1`) — no .NET SDK required.

## Quick start

```powershell
# 1. Get the code anywhere; the default Root is D:\dev\disk-monitor
git clone https://github.com/ufft47/ssd-write-monitor.git D:\dev\disk-monitor

# 2. Health check / one-shot status (no admin needed)
& 'D:\dev\disk-monitor\status.ps1'

# 3. Register the sampler (one task, runs every minute, no console window)
& 'D:\dev\disk-monitor\setup-task.ps1'

# 4a. Build the ETW collector once (built-in csc.exe, no SDK; skip if cwatch.exe exists)
& 'D:\dev\disk-monitor\src\cwatch\build.ps1'

# 4b. Install the ETW collector (elevated; runs a self-test first)
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','D:\dev\disk-monitor\install-collector.ps1'

# 5. Open the dashboard
Start-Process 'http://localhost:8737/'

# 6. Read the reports
Get-ChildItem 'D:\dev\disk-monitor\reports'
```

Every script accepts `-Root <path>`, so you can keep the code somewhere else
(e.g. `-Root 'C:\tools\ssd-write-monitor'`). The default is just the author's layout.

Scheduled tasks created by the project:

| Task | Runs as | Purpose |
|---|---|---|
| `DiskMonitor` | your user (S4U, no window) | Sample every minute; produce the hourly report when an hour completes |
| `CWatchCollector` | **highest privileges** | ETW kernel session → attribution CSV |
| `CWatchTray` | your user | Tray icon, and starts the dashboard |

## Repository layout

```
disk-monitor/
├── src/
│   ├── disk-monitor-run.ps1      single entry point for the scheduled task
│   ├── disk-sample.ps1           60-second sampler (physical disks)
│   ├── disk-report.ps1           hourly report
│   ├── disk-daily.ps1            daily comparison + SMART reconciliation
│   ├── cwatch/                   C# ETW collector + native dependencies (see NOTICE.md)
│   ├── dashboard/                HTTP dashboard on 8737
│   └── tray/                     tray icon
├── *.ps1                         setup, status, diagnostics, and one-off move/cleanup helpers
├── docs/                         project notes (history, TODO, backlog, GitHub workflow)
├── data/                         (gitignored) raw + derived measurements
├── reports/                      (gitignored) generated reports
└── logs/                         (gitignored) script logs
```

## Notes on the move / cleanup helpers

`move-*.ps1`, `avg-*.ps1`, `remove-*.ps1`, `purge-leftovers.ps1` and `reset-traynotify.ps1`
are **real scripts used on the author's machine**. They contain concrete paths such as
`D:\<target>\...` and references to specific products (AVG, ASUS IME, Quark, Edge, Chrome).
They are included as worked examples — read them, then change the paths for your own system.
Nothing in the measurement pipeline depends on them.

`reset-traynotify.ps1` is the one exception that is widely useful as-is: it fixes
`explorer.exe` burning 41–43 % of a core by resetting the bloated `TrayNotify` icon cache
(see the Chinese README for the xperf stack).

## FAQ

**Do I need to run everything as administrator?**
No. Only the ETW collector needs elevation. Sampling, reporting, the dashboard and all
`-DryRun`/`-Verify` modes work as a normal user.

**Does it upload anything?**
No. Everything is written to local files under `data\`, `reports\` and `logs\`. The only
network listener is the dashboard on `localhost:8737`, bound locally; there is no telemetry,
no remote API, no cloud.

**How much overhead does it add?**
The sampler runs once a minute and takes well under a second. The ETW collector is a small
C# process that buffers to disk. Raw CSVs cost a few megabytes per day for `phys`, and more
for `attrib` if the machine is busy.

**Why can't I see a process for some writes?**
Unbuffered I/O, memory-mapped write-back and kernel-internal writes (registry hives, NTFS
metadata) have no owning process at the ETW layer. Those bytes appear in the physical total
but not in the attribution table — that gap is expected.

## Limitations (read before trusting a number)

- **Unbuffered / kernel-internal writes cannot be attributed.** Registry hives, NTFS journal
  and metadata, and mapped page write-back are physically real but have no process.
- **Single-event attribution can be wrong.** Filter rows with `clean-attrib.ps1`, which drops
  attributions that cannot exist (e.g. a "file" that is actually a directory) and reconciles
  per physical disk.
- **Physical counters reset on reboot**, and **device numbers can swap** across reboots. Both
  are handled by splitting segments at resets and keying on volume labels — but a segment
  boundary always loses a small window.
- **SMART is a 1 GB-resolution, once-a-day snapshot.** Daily reconciliation uses a ±20 %
  threshold (configurable) and is a smell detector, not a measurement.
- **ETW under heavy load can drop events**; the collector reports session statistics.
- **Windows only.** It relies on `PhysicalDisk` perf counters, ETW Kernel-File and
  `mklink /J`.

## License and credits

MIT — see [LICENSE](LICENSE).

Third-party binaries under `src/cwatch/lib/` belong to Microsoft and are redistributed as
build dependencies; see [NOTICE.md](NOTICE.md) for the list and their terms.
