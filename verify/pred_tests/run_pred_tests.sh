#!/bin/bash
# run_pred_tests.sh -- build & run the branch-predictor directed tests (a..g).
# Usage: run_pred_tests.sh [test ...]   (default: all)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/.."
RTL="$VERIFY/../rtl"
BUILD="$HERE/build"
XP="$VERIFY/../tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin"
CC="$XP/riscv-none-elf-gcc"
OSS="$VERIFY/../tools/oss-cad-suite/bin"
IV="$OSS/iverilog"
VP="$OSS/vvp"

mkdir -p "$BUILD"
echo "== compiling sim =="
"$IV" -g2012 -o "$BUILD/sim.vvp" -s tb_rv32imc \
  "$VERIFY/tb/tb_rv32imc.v" \
  "$RTL/rv32imc_top.v" "$RTL/branch_pred.v" "$RTL/alu.v" \
  "$RTL/regfile.v" "$RTL/csr.v" "$RTL/compressed_decoder.v" "$RTL/mul_div.v" \
  || { echo "SIM COMPILE FAILED"; exit 1; }

TESTS="${*:-a b c d e f g}"
for t in $TESTS; do
  echo "== test_$t =="
  "$CC" -march=rv32imc_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
    -nostdlib -nostartfiles -T "$VERIFY/sim.ld" \
    -I"$HERE" "$HERE/test_$t.S" -o "$BUILD/test_$t.elf" \
    || { echo "BUILD FAILED: test_$t"; exit 1; }
  rm -rf "$BUILD/t$t"
  python3 "$VERIFY/scripts/elf2hex.py" "$BUILD/test_$t.elf" "$BUILD/t$t" \
    --objcopy "$XP/riscv-none-elf-objcopy" --nm "$XP/riscv-none-elf-nm" >/dev/null \
    || { echo "ELF2HEX FAILED: test_$t"; exit 1; }
  TOHOST=$(grep -E '^tohost=' "$BUILD/t$t/test_$t.info" | cut -d= -f2 | sed 's/^0x//')
  timeout 60 "$VP" -n "$BUILD/sim.vvp" "+hex=$BUILD/t$t/test_$t.hex" "+tohost=$TOHOST" \
    > "$BUILD/test_$t.log" 2>&1
  tail -8 "$BUILD/test_$t.log" | grep -E 'REPORT|RESULT' || tail -3 "$BUILD/test_$t.log"
done
