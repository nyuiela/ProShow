#!/usr/bin/env zsh
# Drive ProShow via localhost Control API while sampling CPU/RAM footprint.
set -euo pipefail

API="${PROSHOW_CONTROL_URL:-http://127.0.0.1:55076}"
DURATION="${1:-120}"
INTERVAL="${2:-5}"
OUT="${3:-/tmp/proshow_load_test_$(date +%Y%m%d_%H%M%S).csv}"

api() {
  local method="$1" path="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    /usr/bin/curl -sS -m 15 -X "$method" "$API$path" -H 'Content-Type: application/json' -d "$body"
  else
    /usr/bin/curl -sS -m 15 -X "$method" "$API$path"
  fi
}

pid="$(pgrep -x ProShow | head -1 || true)"
if [[ -z "$pid" ]]; then
  echo "ProShow is not running. Launch /Applications/ProShow.app and open a project first." >&2
  exit 1
fi

echo "ProShow PID=$pid API=$API duration=${DURATION}s interval=${INTERVAL}s"
echo "timestamp,elapsed_s,rss_mb,footprint_mb,footprint_peak_mb,cpu_pct,threads,is_streaming,is_recording,live_index" > "$OUT"

health="$(api GET /v1/health || true)"
if [[ "$health" != *'"ok":true'* ]]; then
  echo "Control API not reachable at $API ($health)" >&2
  exit 1
fi

echo "Preflight: $(api GET /v1/preflight | head -c 200)..."

# Go live on first program slide, then start encode paths.
api GET /v1/presentation/active/0/trigger >/dev/null || true
sleep 1
stream_result="$(api POST /v1/stream/start '{}')"
record_result="$(api POST /v1/record/start '{}')"
echo "stream/start: $stream_result"
echo "record/start: $record_result"

start_epoch=$(date +%s)
end_epoch=$((start_epoch + DURATION))
tick=0

while [[ $(date +%s) -lt $end_epoch ]]; do
  elapsed=$(( $(date +%s) - start_epoch ))
  # Operator-style churn: advance cue, jump indices, layer clears, telemetry.
  case $((tick % 6)) in
    0) api GET /v1/presentation/active/next/trigger >/dev/null || true ;;
    1) api GET /v1/presentation/active/prev/trigger >/dev/null || true ;;
    2) api GET "/v1/presentation/active/$((tick % 5))/trigger" >/dev/null || true ;;
    3) api GET /v1/clear/layer/media >/dev/null || true ;;
    4) api POST /v1/slide/next '{}' >/dev/null || true ;;
    5) api GET /v1/telemetry >/dev/null || true ;;
  esac

  pid="$(pgrep -x ProShow | head -1 || echo "$pid")"
  rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
  cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo 0)
  threads=$(ps -M -p "$pid" 2>/dev/null | wc -l | tr -d ' ')
  threads=$((threads > 0 ? threads - 1 : 0))
  vm=$(vmmap --summary "$pid" 2>/dev/null || true)
  footprint=$(print -r -- "$vm" | rg "Physical footprint:" | rg -o '[0-9.]+[MGK]' | head -1 || echo "")
  peak=$(print -r -- "$vm" | rg "Physical footprint \(peak\):" | rg -o '[0-9.]+[MGK]' | head -1 || echo "")
  # Normalize to MB when suffix is M
  fp_mb=$(echo "$footprint" | sed 's/M$//')
  peak_mb=$(echo "$peak" | sed 's/M$//')
  rss_mb=$(awk -v r="$rss_kb" 'BEGIN { printf "%.1f", r/1024 }')

  status_json="$(api GET /v1/status 2>/dev/null || echo '{}')"
  streaming=$(echo "$status_json" | rg -o '"is_streaming":(true|false)' | cut -d: -f2 || echo "")
  recording=$(echo "$status_json" | rg -o '"is_recording":(true|false)' | cut -d: -f2 || echo "")
  index=$(echo "$status_json" | rg -o '"active_slide_index":[0-9]+' | cut -d: -f2 || echo "")

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "$ts,$elapsed,$rss_mb,${fp_mb:-},${peak_mb:-},$cpu,$threads,$streaming,$recording,$index" >> "$OUT"

  tick=$((tick + 1))
  sleep "$INTERVAL"
done

api POST /v1/stream/stop '{}' >/dev/null || true
api POST /v1/record/stop '{}' >/dev/null || true

echo "Samples written to $OUT"
python3 << PY
import csv, statistics, sys
path = "$OUT"
rows = list(csv.DictReader(open(path)))
nums = lambda k: [float(r[k]) for r in rows if r.get(k) and r[k].replace('.','',1).isdigit()]
rss = nums('rss_mb')
fp = nums('footprint_mb')
cpu = nums('cpu_pct')
print('--- summary ---')
print(f'samples: {len(rows)}')
if rss:
    print(f'RSS MB  min/avg/max: {min(rss):.1f} / {statistics.mean(rss):.1f} / {max(rss):.1f}')
if fp:
    print(f'Footprint MB min/avg/max: {min(fp):.1f} / {statistics.mean(fp):.1f} / {max(fp):.1f}')
if cpu:
    print(f'CPU %   min/avg/max: {min(cpu):.1f} / {statistics.mean(cpu):.1f} / {max(cpu):.1f}')
stream_on = sum(1 for r in rows if r.get('is_streaming')=='true')
record_on = sum(1 for r in rows if r.get('is_recording')=='true')
print(f'streaming samples true: {stream_on}/{len(rows)}')
print(f'recording samples true: {record_on}/{len(rows)}')
PY
