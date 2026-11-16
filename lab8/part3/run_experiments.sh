#!/usr/bin/env bash
# Runs the four Part 3 experiments against one live replay, logs into part3/output/.
#
# Run 1 (topic payments, normal data), consumers reading live while the producer sends:
#   baseline.log           lateness 120 s, group g-base; killed after 60 s, restarted 60 s later (exp. 1)
#   late0.log              lateness 0, group g-late0                                            (exp. 4)
#   pair-A.log, pair-B.log two consumers in group g-pair, they split the 3 partitions          (exp. 2)
# Run 2 (topic payments-fail, 30% of successes forced to fail):
#   fail30.log             lateness 120 s, group g-fail                                         (exp. 3)
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=part3/output
mkdir -p "$OUT"
START=2026-10-01T08:00:00Z
LIMIT=${LIMIT:-12000}
PY="uv run --quiet"
C="part3/consumer.py --idle-exit 20"

echo "== run 1: payments"
$PY $C --group g-base  --name base       > "$OUT/baseline.log" 2>&1 & BASE=$!
$PY $C --group g-late0 --name late0 --lateness 0 > "$OUT/late0.log" 2>&1 &
$PY $C --group g-pair  --name A --quiet  > "$OUT/pair-A.log" 2>&1 &
sleep 4
$PY $C --group g-pair  --name B --quiet  > "$OUT/pair-B.log" 2>&1 &
sleep 6
$PY part3/producer.py --start "$START" --limit "$LIMIT" > "$OUT/producer.log" 2>&1 & PROD=$!

sleep 30
docker exec lab8-redpanda-redpanda-1 rpk group describe g-pair > "$OUT/group-g-pair.txt" 2>&1
sleep 30
echo "== experiment 1: killing the baseline consumer (pid $BASE)"
echo "---- consumer killed at $(date +%T), restarting in 60 s ----" >> "$OUT/baseline.log"
taskkill //F //T //PID "$(cat /proc/$BASE/winpid 2>/dev/null || echo $BASE)" >/dev/null 2>&1 || kill -9 "$BASE"
sleep 60
echo "---- consumer restarted at $(date +%T) ----" >> "$OUT/baseline.log"
$PY $C --group g-base --name base-restarted >> "$OUT/baseline.log" 2>&1 &

wait $PROD
echo "== run 1 produced; waiting for consumers to go idle"
wait

echo "== run 2: payments-fail, 30% failures"
docker exec lab8-redpanda-redpanda-1 rpk topic create payments-fail -p 3 -r 1 >/dev/null 2>&1 || true
$PY $C --topic payments-fail --group g-fail --name fail30 > "$OUT/fail30.log" 2>&1 &
sleep 6
$PY part3/producer.py --topic payments-fail --start "$START" --limit "$LIMIT" --fail-rate 0.3 \
  > "$OUT/producer-fail30.log" 2>&1
wait
docker exec lab8-redpanda-redpanda-1 rpk group describe g-base > "$OUT/group-g-base.txt" 2>&1
echo "== done"; tail -n 3 "$OUT"/*.log
