#!/bin/bash
# run.sh -- simulate CoreMark in Icarus Verilog (self-contained).
set -euo pipefail
OUT="$(cd "$(dirname "$0")" && pwd)/build_o3"
TIMEOUT="${1:-20000000}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/.."
RTL="$HERE/../../rtl"
OSS=~/workspace/rv32imc-cpu/tools/oss-cad-suite/bin
VV="$OUT/sim_coremark.vvp"
if [[ ! -f "$VV" ]]; then
  echo "== compiling tb + RTL with iverilog..."
  $OSS/iverilog -g2012 -o "$VV" -s tb_rv32imc \
    "$VERIFY/tb/tb_rv32imc.v" \
    "$RTL/rv32imc_top.v" "$RTL/branch_pred.v" "$RTL/alu.v" \
    "$RTL/regfile.v" "$RTL/csr.v" "$RTL/compressed_decoder.v" "$RTL/mul_div.v"
fi
TOHOST="$(grep '^tohost=' "$OUT/coremark.info" | cut -d= -f2 | sed 's/^0x//')"
echo "== running vvp (+hex=$OUT/coremark.hex +tohost=$TOHOST +timeout=$TIMEOUT)"
START=$(date +%s)
$OSS/vvp -n "$VV" "+hex=$OUT/coremark.hex" "+tohost=$TOHOST" "+timeout=$TIMEOUT" 2>&1 | tee "$OUT/run.log"
END=$(date +%s)
echo "== wall time: $((END - START)) s"
