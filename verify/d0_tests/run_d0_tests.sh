#!/bin/bash
# run_d0_tests.sh -- build & run the D0 directed tests
# (imem_wait/dmem_wait stimulus, machine interrupts, predictor liveness).
# Usage: ./run_d0_tests.sh [logdir]
# Logs land in <logdir> (default: ./logs).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/.."
RTL="$VERIFY/../rtl"
BUILD="$HERE/build"
LOGDIR="${1:-$HERE/logs}"
XP="$VERIFY/../tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin"
CC="$XP/riscv-none-elf-gcc"
OSS="$VERIFY/../tools/oss-cad-suite/bin"
IV="$OSS/iverilog"
VP="$OSS/vvp"

mkdir -p "$BUILD" "$LOGDIR"
echo "== compiling sim =="
"$IV" -g2012 -o "$BUILD/sim.vvp" -s tb_rv32imc \
  "$VERIFY/tb/tb_rv32imc.v" \
  "$RTL/rv32imc_top.v" "$RTL/branch_pred.v" "$RTL/alu.v" \
  "$RTL/regfile.v" "$RTL/csr.v" "$RTL/compressed_decoder.v" "$RTL/mul_div.v" \
  || { echo "SIM COMPILE FAILED"; exit 1; }

build_one() { # $1 = test name (no .S)
  "$CC" -march=rv32imc_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
    -nostdlib -nostartfiles -T "$VERIFY/sim.ld" \
    -I"$VERIFY/pred_tests" "$HERE/$1.S" -o "$BUILD/$1.elf" || return 1
  rm -rf "$BUILD/d$1"
  python3 "$VERIFY/scripts/elf2hex.py" "$BUILD/$1.elf" "$BUILD/d$1" \
    --objcopy "$XP/riscv-none-elf-objcopy" --nm "$XP/riscv-none-elf-nm" >/dev/null || return 1
}

run_one() { # $1 = test name, $2 = log tag, rest = plusargs
  local t=$1 tag=$2; shift 2
  local tohost
  tohost=$(grep -E '^tohost=' "$BUILD/d$t/$t.info" | cut -d= -f2 | sed 's/^0x//')
  timeout 180 "$VP" -n "$BUILD/sim.vvp" "+hex=$BUILD/d$t/$t.hex" "+tohost=$tohost" "$@" \
    > "$LOGDIR/$t.$tag.log" 2>&1
  echo "$t [$tag] -> $(grep -E '\[TB\] RESULT' "$LOGDIR/$t.$tag.log" | tail -1)"
}

for t in test_wait_mix test_wait_misp test_wait_loaduse test_wait_soc \
         test_irq_timer test_irq_prio test_irq_mask test_pred_alive; do
  build_one "$t" || { echo "BUILD FAILED: $t"; exit 1; }
done

# (a) wait stimulus: golden + imem/dmem/both LFSR variants, checksum compared
run_one test_wait_mix base
run_one test_wait_mix imem  +imem_wait_pat=1
run_one test_wait_mix dmem  +dmem_wait_pat=1
run_one test_wait_mix both  +imem_wait_pat=1 +dmem_wait_pat=1
# wait during mispredict: window covers the JAL resolve
run_one test_wait_misp win   +imem_wait_pat=2 +wait_win0=1 +wait_win1=20
# wait during load-use
run_one test_wait_loaduse dmem +dmem_wait_pat=1
# SoC-like address-change-triggered 2-wait (the wait x mispredict corner):
# I-port only, D-port only, and both. Catches the c.jal retire bug that
# registered patterns miss.
run_one test_wait_soc soc_imem +imem_wait_pat=3
run_one test_wait_soc soc_dmem +dmem_wait_pat=3
run_one test_wait_soc soc_both +imem_wait_pat=3 +dmem_wait_pat=3
# (b)(c)(d) interrupts
run_one test_irq_timer timer
run_one test_irq_prio  prio
run_one test_irq_mask  mask
# (e) predictor liveness
run_one test_pred_alive alive

echo "== checking =="
python3 "$HERE/check_d0.py" "$LOGDIR"
