#!/bin/bash
# run_synth.sh - run Yosys synthesis + STA estimate for rv32imc_top.
# Usage: ./run_synth.sh [CLOCK_PERIOD]
# Example: ./run_synth.sh 8.333   (default, 120 MHz margin probe)
#          ./run_synth.sh 10.0    (100 MHz sign-off target)
set -euo pipefail
source "$(dirname "$0")/env.sh"

PERIOD="${1:-8.333}"
DESIGN_DIR="$RV32IMC_TOP/pnr/design/rv32imc_top"
FLOW_DIR="$RV32IMC_TOP/tools/orfs/flow"

# Generate constraint.sdc from the template with the requested period
sed "s/@CLOCK_PERIOD@/$PERIOD/" "$DESIGN_DIR/constraint.sdc.template" > "$DESIGN_DIR/constraint.sdc"

# PDK: volare layout -> <pdk>/volare/sky130/versions/<ver>/sky130A
export PDK_ROOT="$RV32IMC_TOP/pdk/volare/sky130/versions/c6d73a35f524070e85faff4a6a9eef49553ebc2b"

echo "=== synthesis: rv32imc_top @ ${PERIOD}ns (target $(python3 -c "print(f'{1000/$PERIOD:.1f}')") MHz) ==="
make -C "$FLOW_DIR" \
  DESIGN_CONFIG="$DESIGN_DIR/config.mk" \
  CLOCK_PERIOD="$PERIOD" \
  synth 2>&1 | tee "$RV32IMC_TOP/pnr/reports/synth_${PERIOD}ns.log"

echo "=== done. results in $FLOW_DIR/results/sky130hd/rv32imc_top/ ==="
