#!/bin/bash
# run_perf_tests.sh -- generate, build, run and check the branch-predictor
# PERFORMANCE characterization tests (h1..h7, i1..i2, j1..j3).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "== generating perf tests =="
python3 "$HERE/gen_perf_tests.py" || exit 1
echo "== building & running =="
"$HERE/run_pred_tests.sh" h1 h2 h3 h4 h5 h6 h7 i1 i2 j1 j2 j3 || exit 1
echo "== checking =="
python3 "$HERE/check_perf.py" "$HERE/build"
