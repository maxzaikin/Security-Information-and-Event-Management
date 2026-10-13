# logspace-capacity

Daily capacity analytics for the LogSpace event storage (MaxPatrol SIEM, Event Storage role):
how much disk one event costs, when size-based rotation (tailcutter) starts,
how many days of events will be retained, and how flow changes affect it.

## Layout

| Path | Runs on | Purpose |
|---|---|---|
| `scripts/collect_logspace_metrics.sh` | MP SIEM Events Storage | Collects events per category, `backup_tool listpart`, `df`, tailcutter health into one CSV |
| `notebooks/logspace_capacity.ipynb` | Jupyter | Analysis, forecasts (Linear, Holt-Winters, LSTM), daily OK/WARN/CRIT summary |
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
pip install -r requirements.txt        # add `torch` to enable the LSTM model
jupyter notebook notebooks/logspace_capacity.ipynb
```

The server CSV is overwritten on every run. Every day copy it to the workstation and append its rows
(without the header) to the Excel master file set in `METRICS_XLSX`, then `Restart & Run All`
and read section 10 first.
