# logspace-capacity

Daily capacity analytics for the LogSpace event storage (MaxPatrol SIEM, Event Storage role):
how much disk one event costs, when size-based rotation (tailcutter) starts,
how many days of events will be retained, and how flow changes affect it.

## Layout

| Path | Runs on | Purpose |
|---|---|---|
| `collect/collect_logspace_metrics.sh` | MP SIEM Events Storage | Collects events per category, `backup_tool listpart`, `df`, tailcutter health into one CSV |
| `notebooks/logspace_capacity.ipynb` | Jupyter | Analysis, forecasts (Linear, Holt-Winters, LSTM), daily OK/WARN/CRIT summary |
| `METHODOLOGY.md` | — | Daily routine, how to read charts, actions (in Russian) |

## Quick start

On the Events Storage server:

```bash
chmod +x collect/collect_logspace_metrics.sh
./collect/collect_logspace_metrics.sh -f 2026-01-01 -t "$(date -d yesterday +%F)"   # one-time backfill
./collect/collect_logspace_metrics.sh                                                 # daily (cron)
```

On the workstation:

```bash
pip install -r requirements.txt        # add `torch` to enable the LSTM model
jupyter notebook notebooks/logspace_capacity.ipynb
```

Copy `logspace_metrics.csv` next to the notebook (or set `METRICS_CSV`), then `Restart & Run All`
and read section 10 first.
