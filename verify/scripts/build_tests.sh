#!/bin/bash
# build_tests.sh -- compile riscv-tests ISA suites for rv32imc and
# convert each test to a $readmemh hex + .info (tohost address).
#
# Env:
#   RISCV_CC      C compiler driver (default: riscv64-unknown-elf-gcc)
#   RISCV_OBJCOPY objcopy           (default: riscv64-unknown-elf-objcopy)
#   RISCV_NM      nm                (default: riscv64-unknown-elf-nm)
# Suites built: rv32ui rv32um rv32uc  (physical "-p-" tests only)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$(dirname "$HERE")"
TESTS_DIR="$VERIFY/riscv-tests"
OUT="$VERIFY/build/tests"
SIM_LD="$VERIFY/sim.ld"

CC="${RISCV_CC:-riscv64-unknown-elf-gcc}"
export RISCV_OBJCOPY="${RISCV_OBJCOPY:-riscv64-unknown-elf-objcopy}"
export RISCV_NM="${RISCV_NM:-riscv64-unknown-elf-nm}"

if [[ ! -d "$TESTS_DIR/isa" ]]; then
  echo "error: riscv-tests not found at $TESTS_DIR" >&2
  echo "hint: git clone https://github.com/riscv/riscv-tests.git $TESTS_DIR" >&2
  exit 1
fi

CFLAGS="-march=rv32imc_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden \
  -nostdlib -nostartfiles -O2 \
  -I$TESTS_DIR/isa -I$TESTS_DIR/env/p -I$TESTS_DIR/isa/macros/scalar \
  -T$SIM_LD"

mkdir -p "$OUT"
count=0
for suite in rv32ui rv32um rv32uc; do
  for src in "$TESTS_DIR"/isa/$suite/*.S; do
    base="$(basename "$src" .S)"
    # build-time name follows the riscv-tests convention: <suite>-p-<test>
    # (the "-p-" = physical-address variant; sources are shared with -v-)
    name="${suite}-p-${base}"
    elf="$OUT/$name.elf"
    if [[ ! -f "$elf" ]]; then
      # shellcheck disable=SC2086
      $CC $CFLAGS "$src" -o "$elf"
    fi
    if [[ ! -f "$OUT/$name.hex" ]]; then
      python3 "$VERIFY/scripts/elf2hex.py" "$elf" "$OUT" >/dev/null
    fi
    count=$((count + 1))
  done
done
echo "built $count tests in $OUT"
