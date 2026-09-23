#!/bin/bash
# build.sh -- compile EEMBC CoreMark for the bare-metal RV32IMC CPU.
# Self-contained inside ~/workspace/rv32imc-cpu/verify/coremark/.
set -euo pipefail
ITERS="${1:-10}"
OUT="$(dirname "$0")/build_o3"
OPT="${OPT:--O3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
PORT="$HERE/port"
VERIFY="$HERE/.."
XP=~/workspace/rv32imc-cpu/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin
CC="$XP/riscv-none-elf-gcc"
OBJCOPY="$XP/riscv-none-elf-objcopy"
NM="$XP/riscv-none-elf-nm"
CFLAGS="-march=rv32imc_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
  -nostdlib -nostartfiles -ffreestanding $OPT \
  -DPERFORMANCE_RUN=1 -DITERATIONS=$ITERS \
  -I$SRC -I$PORT -I$OUT \
  -T$VERIFY/sim.ld"
echo "== compiler: $($CC --version | head -1)"
echo "== CFLAGS: $CFLAGS"
mkdir -p "$OUT"
cat > "$OUT/flags_str.h" <<EOF2
#define FLAGS_STR "$OPT -ffreestanding -march=rv32imc_zicsr_zifencei -mabi=ilp32 -DPERFORMANCE_RUN=1 -DITERATIONS=$ITERS"
EOF2
$CC $CFLAGS \
  "$PORT/crt0.S" \
  "$PORT/core_portme.c" \
  "$PORT/ee_printf.c" \
  "$PORT/finish.c" \
  "$PORT/libsup.c" \
  "$SRC/core_list_join.c" \
  "$SRC/core_matrix.c" \
  "$SRC/core_state.c" \
  "$SRC/core_util.c" \
  "$SRC/core_main.c" \
  -lgcc -o "$OUT/coremark.elf"
python3 "$VERIFY/scripts/elf2hex.py" "$OUT/coremark.elf" "$OUT" \
  --objcopy "$OBJCOPY" --nm "$NM"
"$XP/riscv-none-elf-size" "$OUT/coremark.elf"
grep '^tohost=' "$OUT/coremark.info"
echo "== built $OUT/coremark.hex (ITERATIONS=$ITERS)"
