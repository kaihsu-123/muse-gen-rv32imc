#!/bin/bash
# run_flow.sh - full OpenROAD flow (synth -> detailed route) for rv32imc_top on ASAP7.
# Usage: ./run_flow.sh [CLOCK_PERIOD_PS]   (default 667 = 1.50 GHz)
set -euo pipefail
source "$(dirname "$0")/../pnr/env.sh"

PERIOD="${1:-667}"
DESIGN_DIR="$RV32IMC_TOP/pnr_asap7/design/rv32imc_top"
FLOW_DIR="$RV32IMC_TOP/tools/orfs/flow"

sed "s/@CLOCK_PERIOD@/$PERIOD/" "$DESIGN_DIR/constraint.sdc.template" > "$DESIGN_DIR/constraint.sdc"

echo "=== asap7 full flow: rv32imc_top @ ${PERIOD}ps (target $(python3 -c "print(f'{1000/$PERIOD:.2f}')") GHz) ==="
make -C "$FLOW_DIR" \
  DESIGN_CONFIG="$DESIGN_DIR/config.mk" \
  CLOCK_PERIOD="$PERIOD" \
  2>&1 | tee "$RV32IMC_TOP/pnr_asap7/reports/flow_${PERIOD}ns.log"

echo "=== done. results in $FLOW_DIR/results/asap7/rv32imc_top/ ==="
