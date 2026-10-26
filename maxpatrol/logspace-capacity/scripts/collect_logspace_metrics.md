# collect_logspace_metrics.sh

## Overview
Daily collector for LogSpace capacity analytics (MaxPatrol SIEM, Event Storage role). Runs on the **MP SIEM Events Storage** server and writes one CSV per run with everything the capacity notebook needs: events per category, partition sizes, disk usage and rotation health. The CSV files are copied to the workstation and appended to the Excel master file that `notebooks/logspace_capacity.ipynb` reads.

**Read-only.** The script only reads: one aggregation query per day in LogSpace, `backup_tool --cmd listpart`, `df`, the cron tables and the tailcutter log's modification time. It writes only its own CSV and log file. Nothing in LogSpace or on disk is changed or deleted.

---

## What it collects

| `record_type` | `key` | `value` | `metric_date` | Source |
|---|---|---|---|---|
| `events` | `event_src_category` (empty → `Not_Normalized`) | events that day | the day collected | `SELECT event_src_category, count() FROM siem.events WHERE _eventDate = '<day>' GROUP BY …` — aggregated inside LogSpace, no raw events exported |
| `partition` | table: `events` / `counters` / `cp` | partition size, bytes | partition day | `backup_tool --cmd listpart` — every partition currently stored |
| `disk` | `total` / `used` / `avail`; `cold_*` in hybrid mode | bytes | run date | `df -B1` on `DATA_PATH` (and `COLD_PATH`) |
| `health` | `tailcutter_cron` | 1 = a tailcutter job is in cron, 0 = not found | run date | `grep tailcutter /etc/cron* /var/spool/cron` |
| `health` | `tailcutter_log_age_min` | minutes since the tailcutter log was written, −1 = no log | run date | `stat` of `TAILCUTTER_LOG` |

Tailcutter runs every 30 minutes by default, so a log age far above 30 means rotation is not running.

---

## Output

### File names
Each run writes a **new** file in the output directory, named after the run date. Files of earlier days are never touched, so after a weekend or a holiday the files of every missed day are still there.

| Run | File |
|---|---|
| daily (no options) | `logspace_metrics_2026-10-13.csv` |
| `-d 2026-10-10` | `logspace_metrics_2026-10-13_day_2026-10-10.csv` |
| `-f 2026-01-01 -t 2026-10-12` | `logspace_metrics_2026-10-13_backfill_2026-01-01_2026-10-12.csv` |
| `-S` | `logspace_metrics_2026-10-13_snapshot.csv` |

A re-run of the same kind on the same date **overwrites** that file only. Manual runs have a suffix, so a re-run for a missed day does not overwrite the daily file.

The script does not delete old files. One file is about 50–100 KB (mostly `listpart` rows), a few tens of MB per year.

### Format
`;`-separated, header in the first line, dates as `DD.MM.YYYY` — Excel with a Russian locale opens it into columns on double-click.

```
collected_at;metric_date;record_type;key;value
13.10.2026 08:00:05;12.10.2026;events;Firewall;48211934
13.10.2026 08:00:05;12.10.2026;partition;events;9834412032
13.10.2026 08:00:05;13.10.2026;disk;used;478393733120
13.10.2026 08:00:05;13.10.2026;health;tailcutter_cron;1
```

| Column | Meaning |
|---|---|
| `collected_at` | When the run happened, `DD.MM.YYYY HH:MM:SS`. Same for every row of one run |
| `metric_date` | Day the value belongs to, `DD.MM.YYYY` |
| `record_type` | `events` / `partition` / `disk` / `health` |
| `key` | Category, table or metric name. `;` inside a category name is replaced by `,` |
| `value` | Number |

Rows for the same `record_type + metric_date + key` from different runs are resolved by the notebook: the latest `collected_at` wins. Appending the same day twice is safe.

### Log
`logspace_metrics.log` (or `LOG_FILE`) is appended on every run, with a timestamp per line; the same lines go to stderr. The last line of a run:

```
2026-10-13 08:00:41 Run finished: 1187 rows written to /opt/siem-metrics/out/logspace_metrics_2026-10-13.csv, status=OK
```

---

## Options

| Option | Meaning |
|---|---|
| *(none)* | Events for **yesterday by UTC** (LogSpace days are UTC days) + snapshot (partitions, disk, health) |
| `-d YYYY-MM-DD` | Events for that day + snapshot |
| `-f YYYY-MM-DD -t YYYY-MM-DD` | Events for every day in the range (one query per day) + snapshot. Both are required. Takes precedence over `-d` |
| `-S` | Snapshot only, no events query |
| `-o DIR` | Output directory. Must exist, otherwise the script stops with `ERROR: output directory … does not exist` |
| `-h` | Print usage |

### Environment variables
| Variable | Default | Meaning |
|---|---|---|
| `OUT_DIR` | current directory | Output directory (same as `-o`) |
| `LOG_FILE` | `./logspace_metrics.log` | Log file, appended |
| `LS_CLIENT` | `logspace-client` | LogSpace client. Give the full path if it is not in `PATH` (always check for cron) |
| `BACKUP_TOOL` | `/opt/dbtools/bin/backup_tool` | Used for `listpart` |
| `DATA_PATH` | `/opt/logspaced` | LogSpace data directory: `path` in LogSpace `config.xml`, `PathData` of the Event Storage role |
| `COLD_PATH` | *(empty)* | Cold data directory in hybrid storage mode (`ColdPathData`); empty = not collected |
| `TAILCUTTER_LOG` | `/opt/dbtools/log/tailcutter.log` | Tailcutter log |

Both the default `OUT_DIR` and `LOG_FILE` depend on the **current directory**. Under cron that is the user's home directory unless the command does `cd` first — always set `-o` and `LOG_FILE` explicitly there.

### Exit code
| Code | Meaning |
|---|---|
| `0` | Everything collected, `status=OK` |
| `1` | Wrong arguments, missing output directory, or `status=PARTIAL`: at least one step failed (events query, `listpart`, `df`). The file is still written with what was collected — see the `ERROR` lines in the log |

---

## Installation

On the Events Storage server:

```bash
mkdir -p /opt/siem-metrics/out
cp collect_logspace_metrics.sh /opt/siem-metrics/
chmod 750 /opt/siem-metrics/collect_logspace_metrics.sh
```

- Any directory works; `/opt/siem-metrics` is the recommendation.
- Do **not** put it into vendor directories (`/opt/logspaced`, `/opt/dbtools`): a product update may overwrite them, and nothing foreign belongs in the LogSpace data directory.
- Do not use `/tmp`: it may be cleaned on reboot.
- Check that the data path is right: `path` in LogSpace `config.xml` (default `/opt/logspaced`). If it differs, set `DATA_PATH`.

---

## Account and permissions

### Which account
The script needs:
- to run `logspace-client` and read the `siem` database;
- to run `backup_tool --cmd listpart`;
- to read `DATA_PATH` for `df`, the cron tables and the tailcutter log;
- to write to the output directory and the log file.

Which minimal rights `backup_tool listpart` and `logspace-client` require is **not described in the PT documentation available to us**. The vendor documentation runs `backup` as the `logspace` user. Find out with the checks below, before choosing between root and a non-root account.

A dedicated service account is better than a personal one: a personal account gets locked, its password expires, or it is removed when the person leaves — and collection silently stops.

**Non-root caveat:** `/var/spool/cron` (other users' crontabs, including root's) is not readable by a normal user. If the tailcutter job lives there, a non-root run reports `tailcutter_cron = 0`, and the notebook shows a false **CRIT "tailcutter in cron: NO"**. Check where the job is: `sudo grep -rl tailcutter /etc/cron* /var/spool/cron`. If it is only in `/var/spool/cron`, either run as root or treat that check as unreliable.

### Directory permissions
Replace `<user>` with the account that will run the script:

```bash
sudo -u <user> test -w /opt/siem-metrics     && echo "dir: write OK"
sudo -u <user> test -w /opt/siem-metrics/out && echo "out: write OK"
sudo -u <user> test -x /opt/siem-metrics/collect_logspace_metrics.sh && echo "script: exec OK"
```

Fix, for a dedicated account `siem-metrics`:
```bash
chown -R siem-metrics:siem-metrics /opt/siem-metrics
chmod 750 /opt/siem-metrics /opt/siem-metrics/out
```
For root: `chown -R root:root …` with the same modes. The output contains category names and disk sizes — keep the directory closed to other users.

### Tool access
Test each tool as that account:
```bash
sudo -u <user> which logspace-client
sudo -u <user> logspace-client -q "SELECT 1"
sudo -u <user> /opt/dbtools/bin/backup_tool --cmd listpart | head
sudo -u <user> df -B1 /opt/logspaced
sudo -u <user> stat /opt/dbtools/log/tailcutter.log
```

### Trial run
A run in a clean environment shows what cron will see (empty environment, minimal `PATH`). One query for yesterday — a light load:

```bash
sudo -u <user> env -i HOME=/tmp PATH=/usr/bin:/bin SHELL=/bin/sh \
  LOG_FILE=/opt/siem-metrics/logspace_metrics.log \
  /opt/siem-metrics/collect_logspace_metrics.sh -d "$(date -u -d yesterday +%F)" -o /opt/siem-metrics/out
echo "exit=$?"
```

Expected: `exit=0`, lines `OK: events …`, `OK: listpart …`, `OK: df …`, `OK: health …`, and `status=OK` at the end; a file `logspace_metrics_<today>_day_<yesterday>.csv` in `out`.

| Message | Cause | Fix |
|---|---|---|
| `logspace-client: command not found` | Not in the minimal `PATH` | `LS_CLIENT=/full/path/logspace-client` (find it with `which logspace-client`) |
| `ERROR: events query failed for … (rc=…)` | No access to LogSpace or the query failed | Run the query by hand as that account; check the client's error text |
| `WARN: events query for … returned 0 rows` | No events that day (outage, or the day is not in storage any more) | Check the day exists in `listpart` |
| `ERROR: backup_tool listpart failed` | No rights for `backup_tool` | Run it by hand as that account |
| `ERROR: df failed for …` | Wrong `DATA_PATH` / `COLD_PATH` | Check `path` in LogSpace `config.xml` |
| `ERROR: output directory … does not exist` | `-o` points nowhere | `mkdir -p` it |
| `Permission denied` on the CSV or log | Directory permissions | See [Directory permissions](#directory-permissions) |
| `health -> cron=0` while tailcutter is in cron | Non-root account cannot read `/var/spool/cron` | See the non-root caveat above |

---

## When to run: the day boundary

LogSpace splits days by `_eventDate` and keeps one partition per day; both are **UTC days** (LogSpace `now()`
returns UTC). On a server whose OS clock is local, say UTC+11, a run at 00:30 local is 13:30 UTC of the previous day:
"yesterday" by the OS clock has only 13.5 of its 24 hours in LogSpace. The event counts come out partial (and D,
bytes ÷ events, too high), and that day's partition in the same snapshot is about half its usual size.

Therefore the default run collects **yesterday by UTC** (`date -u -d yesterday`). That day is over at any run time:

| Run at (UTC+11 server) | UTC time | Day collected | Complete? |
|---|---|---|---|
| 00:30 local, 26.10 | 13:30, 25.10 | 24.10 | yes, ended 13.5 h ago |
| 12:30 local, 26.10 | 01:30, 26.10 | 25.10 | yes, ended 1.5 h ago |

Check the server's OS clock with `date; date -u; timedatectl | grep "Time zone"`. On a server that runs in UTC
`date -u -d yesterday` is the same as `date -d yesterday`.

Manual modes take the day you give: `-d <day>` and `-f … -t …` are UTC days. Do not ask for the current UTC day
(`date -u +%F`): it is still being written. Days collected by an older version of the script at night are
incomplete; re-collect them once with `-f <first> -t <last>` — any time later is fine, the notebook keeps the newer
rows and ignores event counts taken before their UTC day was over.

Events that arrive late (agent buffers, a source coming back after an outage) are still added to their day after the run. Re-running `-d <day>` the next day picks them up; the notebook takes the newer value.

---

## Daily operation

### Manual run (current practice)
Every working day, e.g. at 08:00:

```bash
LOG_FILE=/opt/siem-metrics/logspace_metrics.log \
  /opt/siem-metrics/collect_logspace_metrics.sh -o /opt/siem-metrics/out
```

Days without a run (weekend, holiday, sick leave) are **not collected by themselves**. On the next working day fill the gap:

```bash
/opt/siem-metrics/collect_logspace_metrics.sh -f <first missed day> -t <yesterday> -o /opt/siem-metrics/out
```

`-f` is the first day that no run collected. On Monday after a Friday run (which collected Thursday) that is Friday: `-f <Friday> -t <Sunday>`.

What a missed day costs: `events` is recoverable with `-f/-t` as long as the day is in storage; `partition` is not lost (`listpart` shows every stored day at once); `disk` and `health` are snapshots of the run moment — there is simply no snapshot for that day, which the forecast tolerates.

### Cron (recommended if allowed)
Cron removes the weekend gaps. Example for a dedicated account, in `/etc/cron.d/siem-metrics` (system cron files have a user field):

```
30 12 * * * siem-metrics LOG_FILE=/opt/siem-metrics/logspace_metrics.log LS_CLIENT=/full/path/logspace-client /opt/siem-metrics/collect_logspace_metrics.sh -o /opt/siem-metrics/out >> /opt/siem-metrics/cron.out 2>&1
```

Or in the account's own crontab (`crontab -e` as that account, **no** user field):

```
30 12 * * * LOG_FILE=/opt/siem-metrics/logspace_metrics.log LS_CLIENT=/full/path/logspace-client /opt/siem-metrics/collect_logspace_metrics.sh -o /opt/siem-metrics/out >> /opt/siem-metrics/cron.out 2>&1
```

- **Time:** any. The default run takes yesterday by UTC, which is always complete ([the day boundary](#when-to-run-the-day-boundary)). With a run at 12:30 local on a UTC+11 server the data is one day fresher than with 00:30.
- **Full paths everywhere:** cron runs with a minimal environment (`PATH=/usr/bin:/bin`) from the home directory.
- **Whose crontab:** `crontab -e` edits the current user's, `sudo crontab -e` root's, `sudo crontab -u <user> -e` that user's. `crontab -l` / `sudo crontab -l` show what is installed.
- **"Permission denied" / "not allowed to use this program" on `crontab -e`:** cron access is limited by `/etc/cron.allow` (if it exists, only listed users may use `crontab`) and `/etc/cron.deny`. Check with `ls -l /etc/cron.allow /etc/cron.deny`; add the account with `echo <user> | sudo tee -a /etc/cron.allow`. If the message is different, look at the exact text first.
- **After the first scheduled run:** `tail -n 20 /opt/siem-metrics/cron.out` must end with `status=OK`, and the day's file must be in `out`.

### Transfer to the workstation
1. Copy every `logspace_metrics_*.csv` that appeared since the last transfer.
2. Oldest first: open each in Excel, select all rows **except the header**, paste under the last filled row of the Excel master file (`METRICS_XLSX` in the notebook). Save as `.xlsx`.
3. Run the notebook: `Kernel → Restart & Run All`.

The first, backfill file goes into the Excel file **with** its header — that is the start of the master file.

---

## First setup: history backfill
Once, off-hours:

```bash
/opt/siem-metrics/collect_logspace_metrics.sh -f 2026-01-01 -t "$(date -u -d yesterday +%F)" -o /opt/siem-metrics/out
```

- Start date: the oldest partition in `backup_tool --cmd listpart`.
- One aggregation query per day; progress `Backfill i/N` in the log. Each query scans one day's partition, so run it outside peak hours.

---

## Limits and open questions
- **Time zone of `_eventDate`** — UTC: confirmed by the incomplete night run on a UTC+11 server (see [the day boundary](#when-to-run-the-day-boundary)); the script now takes yesterday by UTC.
- **`listpart` bytes vs real disk usage** — not documented; the notebook compares `df used` with the sum of partitions (section 3) and shows the ratio.
- **Hybrid storage:** `cold_*` disk rows are collected, but how tailcutter counts the cold storage against its limit is unknown; the notebook forecasts the main path only.
- **Tailcutter in cron as non-root** — see [Account and permissions](#account-and-permissions).
- This version was tested with stubs for `logspace-client` and `backup_tool`; a run on a real Events Storage server is not confirmed yet — do the [trial run](#trial-run) first.

---

## Requirements
- MP SIEM Events Storage server with `logspace-client` and `/opt/dbtools/bin/backup_tool`.
- `bash`, GNU `coreutils` (`date -d`, `df --output`, `stat -c`), `awk`, `grep`.
