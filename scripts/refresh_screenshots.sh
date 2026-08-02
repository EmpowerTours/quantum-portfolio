#!/usr/bin/env bash
# Start Streamlit, capture the submission screenshots, stop it again.
#
# Split out of the Makefile because backgrounding a server, waiting on it and
# then killing it is more shell than a make recipe handles reliably — make runs
# each line in its own /bin/sh and the background job did not survive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="${PY:-.venv/bin/python}"
PORT="${PORT:-8501}"

cleanup() { pkill -f "[s]treamlit run app.py" 2>/dev/null || true; }  # bracket: do not self-match
trap cleanup EXIT

cleanup
sleep 1

echo "starting streamlit on :$PORT"
nohup "$PY" -m streamlit run app.py \
  --server.headless true --server.port "$PORT" \
  > /tmp/streamlit-refresh.log 2>&1 &

for i in $(seq 1 40); do
  if curl -sf -o /dev/null "http://localhost:$PORT"; then
    echo "  up after ${i}s"
    break
  fi
  sleep 1
  if [ "$i" -eq 40 ]; then
    echo "streamlit did not start; last log lines:" >&2
    tail -20 /tmp/streamlit-refresh.log >&2
    exit 1
  fi
done

# Streamlit serves the shell before the app has finished its first run; the
# capture script clicks through tabs and sleeps per tab, but give the initial
# data fetch a moment so the first tab is not caught mid-spinner.
sleep 6

"$PY" scripts/take_screenshots.py
echo "screenshots captured"
