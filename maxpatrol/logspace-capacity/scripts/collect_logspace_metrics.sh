#!/usr/bin/env bash
# =============================================================================
# collect_logspace_metrics.sh
#
# Unified daily collector for LogSpace capacity analytics (MaxPatrol SIEM,
# Event Storage role). Run it on the MP SIEM Events Storage server.
#
# Everything goes into ONE tidy CSV file (appended, never rewritten):
#
#   collected_at;metric_date;record_type;key;value
#
#   collected_at  - when this run happened        (DD.MM.YYYY HH:MM:SS)
#   metric_date   - the day the value belongs to  (DD.MM.YYYY)
#   record_type   - events | partition | disk | health
#   key           - category / table / metric name
#   value         - number
#
#   events     : event count per event_src_category for metric_date
#                (aggregated inside LogSpace with GROUP BY, no raw events)
#   partition  : partition size in bytes from `backup_tool --cmd listpart`
#                (key = table: events / counters / cp)
#   disk       : filesystem size / used / avail in bytes (df -B1) for the
#                LogSpace data path; cold_* keys for the hybrid cold path
#   health     : rotation health indicators (tailcutter cron, log age)
#
# Usage:
#   ./collect_logspace_metrics.sh                         # yesterday + snapshot
#   ./collect_logspace_metrics.sh -d 2026-10-12           # given day + snapshot
#   ./collect_logspace_metrics.sh -f 2026-01-01 -t 2026-10-12   # backfill
#   ./collect_logspace_metrics.sh -o /path/logspace_metrics.csv
#   ./collect_logspace_metrics.sh -S                      # snapshot only (no events)
#
# Environment overrides: OUT_FILE, LOG_FILE, BACKUP_TOOL, LS_CLIENT,
#                        DATA_PATH, COLD_PATH, TAILCUTTER_LOG
# =============================================================================

set -uo pipefail

# ---------- defaults ----------
OUT_FILE="${OUT_FILE:-$(pwd)/logspace_metrics.csv}"
LOG_FILE="${LOG_FILE:-$(pwd)/logspace_metrics.log}"
BACKUP_TOOL="${BACKUP_TOOL:-/opt/dbtools/bin/backup_tool}"
LS_CLIENT="${LS_CLIENT:-logspace-client}"
DATA_PATH="${DATA_PATH:-/opt/logspaced}"        # PathData of Event Storage role
COLD_PATH="${COLD_PATH:-}"                      # ColdPathData, only in hybrid mode
TAILCUTTER_LOG="${TAILCUTTER_LOG:-/opt/dbtools/log/tailcutter.log}"
EMPTY_CATEGORY_LABEL="Not_Normalized"           # label for empty/NULL category

DAY=""
FROM=""
TO=""
SNAPSHOT_ONLY=0

usage() {
    sed -n '/^# Usage:/,/^# Environment/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while getopts "d:f:t:o:Sh" opt; do
    case "$opt" in
        d) DAY="$OPTARG" ;;
        f) FROM="$OPTARG" ;;
        t) TO="$OPTARG" ;;
        o) OUT_FILE="$OPTARG" ;;
        S) SNAPSHOT_ONLY=1 ;;
        *) usage ;;
    esac
done

# ---------- helpers ----------
log() {
    # Timestamped message to stderr and to the log file
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}

is_iso_date() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" >/dev/null 2>&1
}

# ---------- build the list of days for the events section ----------
DAYS=()
if [ "$SNAPSHOT_ONLY" -eq 0 ]; then
    if [ -n "$FROM" ] || [ -n "$TO" ]; then
        if ! is_iso_date "$FROM" || ! is_iso_date "$TO"; then
            log "ERROR: -f and -t must both be valid dates YYYY-MM-DD"; exit 1
        fi
        d="$FROM"
        while [[ ! "$d" > "$TO" ]]; do
            DAYS+=("$d")
            d=$(date -d "$d +1 day" +%F)
        done
    elif [ -n "$DAY" ]; then
        is_iso_date "$DAY" || { log "ERROR: -d must be a valid date YYYY-MM-DD"; exit 1; }
        DAYS=("$DAY")
    else
        DAYS=("$(date -d yesterday +%F)")
    fi
fi

# One timestamp for the whole run: lets the notebook group a snapshot together
TS="$(date '+%d.%m.%Y %H:%M:%S')"
TODAY_DMY="$(date +%d.%m.%Y)"

BUF="$(mktemp)"
TMP="$(mktemp)"
trap 'rm -f "$BUF" "$TMP"' EXIT
FAILED=0

log "Run started: out=$OUT_FILE days=${#DAYS[@]} snapshot=yes"

# ---------- 1. events per category (one aggregation query per day) ----------
collect_events() {
    local day="$1" dmy start rc rows
    dmy="$(date -d "$day" +%d.%m.%Y)"
    start=$(date +%s)

    "$LS_CLIENT" -q "use siem; SELECT event_src_category AS category, count() AS total_events FROM siem.events WHERE _eventDate = '${day}' GROUP BY category ORDER BY category ASC" \
        --format=TabSeparated > "$TMP"
    rc=$?   # capture immediately, before any other command

    if [ $rc -ne 0 ]; then
        log "ERROR: events query failed for $day (rc=$rc)"
        return 1
    fi

    rows=$(wc -l < "$TMP")
    if [ "$rows" -eq 0 ]; then
        log "WARN: events query for $day returned 0 rows"
        return 0
    fi

    # category<TAB>count -> tidy rows; empty/NULL category gets a label,
    # ';' inside category names is replaced to keep the CSV valid
    awk -F'\t' -v ts="$TS" -v d="$dmy" -v empty="$EMPTY_CATEGORY_LABEL" '
        NF >= 2 {
            c = $1
            if (c == "" || c == "\\N") c = empty
            gsub(/;/, ",", c)
            print ts ";" d ";events;" c ";" $NF
        }' "$TMP" >> "$BUF"

    log "OK: events $day -> $rows categories in $(( $(date +%s) - start )) s"
}

i=0
for day in "${DAYS[@]}"; do
    i=$((i + 1))
    [ ${#DAYS[@]} -gt 1 ] && log "Backfill $i/${#DAYS[@]}: $day"
    collect_events "$day" || FAILED=1
done

# ---------- 2. partitions (backup_tool listpart) ----------
if "$BACKUP_TOOL" --cmd listpart > "$TMP"; then
    # "YYYYMMDD table bytes" -> tidy rows; header and blank lines are skipped
    n=$(awk -v ts="$TS" '
        NF == 3 && $1 ~ /^[0-9]{8}$/ && $3 ~ /^[0-9]+$/ {
            d = substr($1,7,2) "." substr($1,5,2) "." substr($1,1,4)
            print ts ";" d ";partition;" $2 ";" $3
        }' "$TMP" | tee -a "$BUF" | wc -l)
    log "OK: listpart -> $n partitions"
else
    log "ERROR: backup_tool listpart failed"
    FAILED=1
fi

# ---------- 3. disk (df) ----------
collect_disk() {
    local path="$1" prefix="$2" line
    if ! line=$(df -B1 --output=size,used,avail "$path" 2>/dev/null | tail -1); then
        log "ERROR: df failed for $path"; return 1
    fi
    read -r size used avail <<< "$line"
    {
        echo "$TS;$TODAY_DMY;disk;${prefix}total;$size"
        echo "$TS;$TODAY_DMY;disk;${prefix}used;$used"
        echo "$TS;$TODAY_DMY;disk;${prefix}avail;$avail"
    } >> "$BUF"
    log "OK: df $path -> used $((used / 1024**3)) GiB of $((size / 1024**3)) GiB"
}

collect_disk "$DATA_PATH" "" || FAILED=1
[ -n "$COLD_PATH" ] && { collect_disk "$COLD_PATH" "cold_" || FAILED=1; }

# ---------- 4. rotation health ----------
# 1 if a tailcutter job exists in cron, else 0
if grep -rqs tailcutter /etc/cron* /var/spool/cron 2>/dev/null; then cron=1; else cron=0; fi
echo "$TS;$TODAY_DMY;health;tailcutter_cron;$cron" >> "$BUF"

# Minutes since tailcutter log was last written (-1 if no log).
# Tailcutter runs every 30 min by default, so a large value means it is not running.
if [ -f "$TAILCUTTER_LOG" ]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$TAILCUTTER_LOG") ) / 60 ))
else
    age=-1
fi
echo "$TS;$TODAY_DMY;health;tailcutter_log_age_min;$age" >> "$BUF"
log "OK: health -> cron=$cron log_age_min=$age"

# ---------- write (append under lock, header only for a new file) ----------
(
    flock -x 9
    [ -s "$OUT_FILE" ] || echo "collected_at;metric_date;record_type;key;value" > "$OUT_FILE"
    cat "$BUF" >> "$OUT_FILE"
) 9>>"$OUT_FILE.lock"

log "Run finished: $(wc -l < "$BUF") rows appended, status=$([ $FAILED -eq 0 ] && echo OK || echo PARTIAL)"
exit $FAILED
