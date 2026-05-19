#!/bin/bash
# Run Gemma depth probe across depths 2, 3, 4, 5 with TWO replicates each
# (run_1 and run_2). Each run: NUCLEAR_RESET, SET_MEMORY_DEPTH:N, drive
# scripted conversation, capture ground-truth depth= from device logs.
# Logs go to /tmp/gemma_depth_<N>_run<R>.log.

set -u
cd "/Users/markfriedlander/Desktop/Fun/Hal Universal"

for D in 2 3 4 5; do
  for R in 1 2; do
    echo "=================================================="
    echo "DEPTH $D RUN $R — start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "=================================================="
    python3 -u tests/gemma_depth_probe.py $D > /tmp/gemma_depth_${D}_run${R}.log 2>&1
    echo "DEPTH $D RUN $R — done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "--- tail ---"
    tail -10 /tmp/gemma_depth_${D}_run${R}.log
    echo
    echo "--- ground-truth depth confirmations ---"
    grep -c "ground-truth: chat ran at depth=" /tmp/gemma_depth_${D}_run${R}.log || true
    echo "--- BUG count (depth taint) ---"
    grep -c "\[BUG\]" /tmp/gemma_depth_${D}_run${R}.log || true
  done
done

echo "=================================================="
echo "ALL DONE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=================================================="
for D in 2 3 4 5; do
  for R in 1 2; do
    echo
    echo "--- depth=$D run=$R summary ---"
    grep -E "RESULT|completed_turns|failure_mode|failing_turn|ground-truth: chat ran at depth=|\\[BUG\\]" /tmp/gemma_depth_${D}_run${R}.log | head -3
  done
done
