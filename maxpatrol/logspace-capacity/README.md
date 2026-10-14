# logspace-capacity

Daily capacity analytics for the LogSpace event storage (MaxPatrol SIEM, Event Storage role):
how much disk one event costs, when size-based rotation (tailcutter) starts,
how many days of events will be retained, and how flow changes affect it.

## Layout

| Path | Runs on | Purpose |
|---|---|---|
| `scripts/collect_logspace_metrics.sh` | MP SIEM Events Storage | Collects events per category, `backup_tool listpart`, `df`, tailcutter health into one CSV per run. Docs: `scripts/collect_logspace_metrics.md` (permissions, cron, day boundary, troubleshooting) |
| `scripts/Get-EventIdInventory.ps1` | Windows workstation | EventID inventory and before/after flow measurement for audit policy / Sysmon changes. Docs: `scripts/Get-EventIdInventory.md` |
| `notebooks/logspace_capacity.ipynb` | Jupyter | Analysis, forecasts (Linear, Holt-Winters, SARIMAX), daily OK/WARN/CRIT summary |
| `METHODOLOGY.md` | — | Daily routine, how to read charts, actions (in Russian) |

## Quick start

On the Events Storage server:

```bash
chmod +x scripts/collect_logspace_metrics.sh
./scripts/collect_logspace_metrics.sh -f 2026-01-01 -t "$(date -d yesterday +%F)"   # one-time backfill
./scripts/collect_logspace_metrics.sh                                                 # daily (cron)
```

On the workstation:

```bash
pip install -r requirements.txt
jupyter notebook notebooks/logspace_capacity.ipynb
```

Each run writes a new file `logspace_metrics_<run date>.csv` (manual `-d` / `-f -t` / `-S` runs get a suffix),
so files of missed days stay on the server. Copy the new files to the workstation and append their rows
(without the header), oldest first, to the Excel master file set in `METRICS_XLSX`, then `Restart & Run All`
and read section 10 first.
