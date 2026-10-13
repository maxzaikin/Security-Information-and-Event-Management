# Get-EventIdInventory PowerShell Script

## Overview
The **`Get-EventIdInventory`** function builds an inventory of what actually shows up in a Windows machine's event logs: one row per unique **log + provider + EventID**, with a description, Task/Keywords, a sample of the event data, the accounts the events fired under, the hit count, first/last seen time and the event rate.

In this project it answers a capacity question for LogSpace: **how much does the event flow from a workstation change after a new audit policy or a Sysmon configuration is deployed**, and which EventIDs make up the difference. See [Before/after measurement](#beforeafter-measurement).

---

## Features
- Enumerates every non-empty event log by default, or a list passed in (`-LogNames`, also via pipeline).
- One row per `(LogName, Provider, EventID)`: the same EventID under different providers is a different event type.
- Optional fixed time window `-From` / `-To`, filtered inside the event log query, for comparable before/after runs.
- `EventsPerDay`: the event rate over the window of the whole log, the measure to compare between runs.
- Log size facts per row (`LogMaxSizeMB`, `LogSizeMB`, `LogMode`, `LogIsFull`, `LogOldestRecord`) to see whether the log is wrapping, and a warning when a `-From`/`-To` window is no longer fully held by the log.
- Full message text (flattened to one line, up to 800 chars) plus a `Name=Value` sample parsed from the raw event XML, which works even for providers with a broken message manifest.
- SID → account name, resolved once per SID.
- Records are read one by one (`EventLogReader`), so a single unreadable record does not abort the whole log.
- `-WhatIf` shows which logs would be read and where the file would go, without reading or writing anything.
- Output: a **tab-separated** file (UTF-8 with BOM, no quoting) — see [Output file](#output-file).
- Nothing is sent to the pipeline: the console shows a run summary only, the data is in the file.

---

## Parameters
| Parameter | Description | Default |
|---|---|---|
| `LogNames` | Log names to process; accepts pipeline input. If omitted, every log with `RecordCount -gt 0`. | all non-empty logs |
| `MaxEventsPerLog` | Max events read from one log, newest first. `0` = no limit, read the log in full. | `50000` |
| `OutputCsv` | Output file path (tab-separated, despite the parameter name). | `.\EventIdInventory_<COMPUTERNAME>_<timestamp>.tsv` |
| `From` | Start of the time window, local time, inclusive. Format `'2026-10-12 13:00'`. | — |
| `To` | End of the time window, local time, exclusive. Requires `-From`; if omitted, now. | — |
| `HighRateThreshold` | Events/minute at or above which `Density` is `High`. | `1.0` |
| `MidRateThreshold` | Events/minute at or above which `Density` is `Mid`. | `0.05` |
| `MinCountForDensity` | Rows with fewer occurrences are always `Density = Low`. | `3` |

Also supports the common `-WhatIf` and `-Confirm` parameters.

**Date format for `-From`/`-To`:** use `yyyy-MM-dd HH:mm`. PowerShell converts `[datetime]` parameters with the invariant culture, so `12-10-2026` may fail or swap day and month.

---

## Loading the function
The file defines a function, not a module. Dot-source it once per session:

```powershell
. .\Get-EventIdInventory.ps1
Get-EventIdInventory -WhatIf
```

---

## Examples

### Full inventory, default limits
```powershell
Get-EventIdInventory
```
Every non-empty log, up to 50000 newest events each.

### Specific logs, no cap
```powershell
Get-EventIdInventory -LogNames 'Security','System','Application' -MaxEventsPerLog 0
```

### Fixed 24 h window
```powershell
Get-EventIdInventory -MaxEventsPerLog 0 -From '2026-10-12 13:00' -To '2026-10-13 13:00'
```

### Preview only
```powershell
Get-EventIdInventory -WhatIf
```

---

## Output file

Tab-separated, UTF-8 with BOM, no quoting. Every value is cleaned before writing:
- runs of whitespace and control characters (tabs, line breaks, `NUL`, `U+2028`/`U+2029` and other characters some readers treat as line breaks) collapse to one space, leading/trailing spaces are trimmed;
- `"` becomes `'` — a field starting with `"` would otherwise be read as a quoted field;
- a text value starting with `=`, `+`, `-` or `@` gets a leading `'`, so Excel does not evaluate it as a formula. Event text such as `CommandLine` can be attacker-controlled (CSV injection). Strip the `'` when you need the original value.

Commas, semicolons and quotes inside event text therefore cannot break the columns. Dates are `yyyy-MM-dd HH:mm:ss`, numbers use a dot as the decimal separator.

Opening it:
- **Excel:** Data → From Text/CSV, delimiter *Tab*. Or open the file in a text editor, copy all and paste into Excel — tabs split into columns.
- **pandas:** `pd.read_csv(path, sep="\t", quoting=csv.QUOTE_NONE, encoding="utf-8-sig")`
- **PowerShell:** `Import-Csv path -Delimiter "`t"`

| Column | Meaning |
|---|---|
| `Workstation` | Computer name |
| `LogName`, `EventID`, `Provider` | Row key |
| `Level`, `LevelRaw` | Level name and number (the name is not resolved for every provider) |
| `Task`, `TaskRaw`, `Opcode`, `Keywords` | On Security, `Task` maps the EventID to the Advanced Audit Policy subcategory |
| `Description` | Full message of one occurrence, one line, up to 800 chars |
| `SampleEventData` | `Name=Value` pairs from one occurrence's raw XML |
| `Users` | Accounts from the event's SID, `; `-separated (empty if the provider does not record it) |
| `Count` | Events read for this row |
| `FirstSeen`, `LastSeen` | First/last occurrence of this row |
| `DurationMinutes`, `EventsPerMinute`, `Density` | Rate over the row's own FirstSeen..LastSeen — shows bursts; **not** for before/after comparison |
| `WindowStart`, `WindowEnd`, `WindowHours` | With `-From/-To`: the requested window. Without: oldest..newest event read from this log |
| `WindowComplete` | With `-From/-To` only: `False` if the log no longer holds the start of the window or reading stopped at `MaxEventsPerLog` |
| `EventsPerDay` | `Count / WindowHours × 24` — **the flow measure to compare between runs** |
| `LogMaxSizeMB`, `LogSizeMB`, `LogMode`, `LogIsFull` | Log configuration. `Circular` with size ≈ max size means the log is overwriting old events |
| `LogOldestRecord` | Time of the oldest record still in the log |

**Why not compare `Count`.** A log holds as much history as fits into its maximum size (Security: 20 MB by default, often changed by GPO). After a new audit policy the same size covers a shorter time, so the `Count` of a full read can stay flat or even drop while the flow grows several times. `EventsPerDay` over a fixed window does not have this problem.

---

## Before/after measurement

Goal: how the event flow from a workstation changes after an audit policy change or a Sysmon deployment, and what that means for LogSpace.

The principle: the two 24 h windows must differ **only** by the change under test. Everything else — the host's state at the start of the window, what runs during it, who works on it, and the side effects of the test itself — has to be the same in both.

### Test scenario

**Calendar.** Three consecutive working days at the same time, **D0 → D1 → D2**, 13:00. Window "before" = D0 13:00 → D1 13:00, window "after" = D1 13:00 → D2 13:00. Each window then holds one working afternoon, one night and one working morning.
- D0 must not be a Friday (the "before" window would contain the weekend), and none of the days a holiday or a short day.
- Avoid Patch Tuesday (second Tuesday of the month) and the days right after it, month-end, planned maintenance, a scheduled full antivirus scan or backup inside either window — check the host's Task Scheduler.
- Example: D0 = Mon **2026-10-19**, D1 = Tue **2026-10-20** (change), D2 = Wed **2026-10-21**. Patch Tuesday 2026-10-13 is the week before.

**Preparation — at least 2 days before D0**, so that none of it lands inside a window:
1. **Hosts.** One or more per role: office user, IT admin, developer, server. The flow depends on the role far more than on the machine.
2. **User.** The same person works on the host on all three days, at the usual hours, as usual. Tell them about the test. A laptop stays on and in the office network: sleep, hibernation or taking it home makes the windows unequal — disable sleep for the test period (`powercfg /change standby-timeout-ac 0`) or use desktops.
3. **Freeze.** Agree with the AD/GPO admins that no other GPO touching these hosts changes until D2. No software installs. Pause Windows Update for the test period. Antivirus signature updates stay as usual.
4. **Log sizes.** Raise the max size of the measured logs, e.g. `wevtutil sl Security /ms:<bytes>`, sized for the "after" flow — the new policy fills the log faster. Do it now, not on D0: the change itself writes events.
5. **SIEM collection.** The MaxPatrol SIEM collection task for the host keeps running unchanged on all three days — its remote logons and queries generate events on the host too.
6. **Do not clear any log** until D2.

**Daily sequence at 13:00 — identical on all three days, same account, same console.** The test's own side effects — the measurement run itself (logon, process creation, PowerShell script block logging), `gpupdate`, the reboot and the user logging on after it — then appear exactly once in each window and cancel out in the delta.

| # | Step | D0 13:00 | D1 13:00 | D2 13:00 |
|---|---|---|---|---|
| 1 | Measurement run | **trial**: `-From '2026-10-18 13:00' -To '2026-10-19 13:00'` — checks rights and that the logs hold 24 h (`LogOldestRecord`, no `INCOMPLETE`) | **before**: `-From '2026-10-19 13:00' -To '2026-10-20 13:00'` | **after**: `-From '2026-10-20 13:00' -To '2026-10-21 13:00'` |
| 2 | Save the state | `auditpol /get /category:* > auditpol_D0.txt`, `gpresult /h gpresult_D0.html`, Sysmon: `sysmon -c > sysmon_D0.txt` | same, `_D1` | same, `_D2` |
| 3 | Change | — | **apply the change** (GPO / local audit policy / Sysmon install or config) | — |
| 4 | `gpupdate /force` | yes | yes | — |
| 5 | Reboot | yes | yes | — |
| 6 | After the reboot | user logs on and works | user logs on; save the state again (`auditpol`, `sysmon -c` → `_D1_after`) to confirm the change is in effect | — |

All measurement runs use `Get-EventIdInventory -MaxEventsPerLog 0 …` under an account that can read every measured log (see [Which account](#️-which-account-to-run-this-as)).

Why `gpupdate /force` and a reboot on D0 too: so that both windows start from the same state — policy freshly applied, fresh boot. Without them on D0 the "after" window alone would contain the boot and logon burst, and it would be counted as an effect of the change.

The run on D2 can be followed by steps 2–5 again if the test continues with a third window.

### Checks before comparing
- No `INCOMPLETE` or `stopped at MaxEventsPerLog` warnings in either run; `WindowComplete = True` and `WindowHours = 24` in every row of both files.
- `auditpol_D0` = `auditpol_D1`; `auditpol_D1_after` differs from `auditpol_D1` only by the planned subcategories. Same for `sysmon -c`.
- The host was up for the whole of both windows, with exactly one boot in each: System log, events 6005/6006 (Event Log service start/stop), 6008 (unexpected shutdown), Kernel-Power 42 (sleep), 1 / Power-Troubleshooter (wake).
- Nothing unusual happened in either window (installs, incidents, a different user, a day off).

If any check fails, the pair is not comparable — repeat the test.

### Comparison
Join the two files on `LogName + Provider + EventID` and compare `EventsPerDay`:
- **New** — present only after the change: what the new policy or Sysmon added.
- **Gone** — present only before.
- **Changed** — `Δ = after − before`, `Δ%`, and each row's share of the total Δ; sort by Δ to see which EventIDs drive the growth.
- Per log and per host: total events/day before and after, Δ, Δ%.

### What it means for LogSpace
- Only logs that the **MaxPatrol SIEM collection task actually collects** matter; growth in a log that is not collected does not reach LogSpace.
- Fleet estimate: Δevents/day per host × number of hosts of that role, summed over roles.
- Bytes: Δevents/day × D, where D is the real bytes per event from the capacity notebook (section 2), not the vendor's 200.
- Put the resulting growth into the notebook's what-if (section 9) to see the effect on retention depth and on the date size rotation starts.
- After the rollout, check the estimate against the real flow in the notebook (events by `event_src_category`) in 1–2 weeks.

### Limits
- One 24 h pair is one sample. Day-to-day noise on a workstation is large; for a decision, repeat on several hosts per role.
- Sysmon may produce a burst right after installation; if the "after" window looks inflated, measure the next 24 h too.

---

## ⚠️ Which Account To Run This As

1. **The Security log** is not readable by a plain standard user. Membership in the built-in local group **"Event Log Readers"** (SID `S-1-5-32-573`) is enough for read access — full local-administrator rights are not required just for that.

2. **Several `Microsoft-Windows-*/Operational` channels**, and in particular the hidden **Analytic/Debug** channels, are ACL'd to Administrators/SYSTEM only; Event Log Readers membership will not open those. Reading them requires local-administrator rights (and, for Analytic/Debug channels, enabling them first with `wevtutil sl <channel> /e:true`), or a channel ACL explicitly widened with `wevtutil sl <channel> /ca:<SDDL>`.

3. **For fleet-wide rollout via GPO/RMM**, the simplest option is a scheduled task running as `NT AUTHORITY\SYSTEM` — SYSTEM has full read access to every log, including Security and the hidden Analytic/Debug channels, with no extra group membership needed.

**Summary:** for a one-off manual run on a single machine, membership in "Event Log Readers" covers Security + Application + System + most Operational logs. For full coverage (including hidden Analytic/Debug) and/or fleet deployment, use SYSTEM (via a scheduled task) or a local administrator account.

> **Note:** the function assumes an interactive run in a PowerShell 7 console — status and progress go to `Write-Host`/`Write-Progress` only, there is no log file. Run unattended (e.g. as a SYSTEM scheduled task), that output is not visible anywhere; add a log-file sink before doing that.

---

## Handling the Output

The file contains Windows account names (including domain accounts), the computer name and event text from the endpoint. Treat it like any other collected audit artifact:
- Store it under access-controlled paths, not general-purpose shares.
- Don't email it unencrypted if the workstation belongs to a regulated scope.
- Never commit it to this repository.

---

## Known Limitations

- **`UserId` is not always populated.** Many system, driver and Application events never carry a SID — for those `Users` is empty. This is a property of the event source.
- **`Description` is one occurrence's message**, not the generic template; parameterized messages differ between occurrences.
- **`MaxEventsPerLog` truncation.** With the default cap a large log may not surface rare EventIDs; with `-From/-To` the cap can cut the window short (a warning is printed). Use `-MaxEventsPerLog 0` for measurements.
- **Unreadable records.** A record that `EventLogReader.ReadEvent()` cannot read is skipped; after 200 such records in a row the log is aborted. Whether the reader always moves past a failed record has not been verified.
- **Windows-only** (`Get-WinEvent`, `System.Diagnostics.Eventing.Reader`).

---

## Requirements
- PowerShell 7+ (developed and tested on 7.x). Windows PowerShell 5.1 is not tested.
- Windows with the Event Log service running.

---

## ⚠️ Disclaimer

All scripts are provided as-is with no implicit warranty or support.

- Always test scripts in a DEV/TEST environment before using them in production.
- Use at your own risk!
