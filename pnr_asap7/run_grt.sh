#!/bin/bash
# run_grt.sh - synth -> floorplan -> place -> CTS -> global route for rv32imc_top on ASAP7.
# Stops before detail route (TritonRoute OOMs on this 7 GB machine; see RESULTS.md).
# Usage: ./run_grt.sh <CLOCK_PERIOD_PS>   e.g. ./run_grt.sh 1000
set -euo pipefail
source "$(dirname "$0")/../pnr/env.sh"

PERIOD="${1:?usage: run_grt.sh <CLOCK_PERIOD_PS>}"
DESIGN_DIR="$RV32IMC_TOP/pnr_asap7/design/rv32imc_top"
FLOW_DIR="$RV32IMC_TOP/tools/orfs/flow"
VARIANT="pred${PERIOD}"

sed "s/@CLOCK_PERIOD@/$PERIOD/" "$DESIGN_DIR/constraint.sdc.template" > "$DESIGN_DIR/constraint.sdc"
# sanity: SDC must carry the intended period in ps (ASAP7 time_unit = 1ps).
# The template assigns it via 'set clk_period <ps>'; create_clock uses $clk_period.
grep -q "^set clk_period ${PERIOD}$" "$DESIGN_DIR/constraint.sdc" \
  || { echo "SDC render check FAILED for period $PERIOD"; exit 1; }

echo "=== asap7 synth..grt: rv32imc_top @ ${PERIOD}ps variant=$VARIANT ==="
make -C "$FLOW_DIR" \
  DESIGN_CONFIG="$DESIGN_DIR/config.mk" \
  CLOCK_PERIOD="$PERIOD" \
  FLOW_VARIANT="$VARIANT" \
  synth floorplan place cts do-grt \
  2>&1 | tee "$RV32IMC_TOP/pnr_asap7/reports/grt_pred_${PERIOD}ps.log"

echo "=== done. results in $FLOW_DIR/results/asap7/rv32imc_top/$VARIANT/ ==="
