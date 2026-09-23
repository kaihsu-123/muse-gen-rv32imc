#!/bin/bash
# run_tests.sh -- RV32IMC CPU 驗證一鍵執行腳本
#
#   ./run_tests.sh
#
# 流程：
#   1. 檢查工具（iverilog / vvp / RISC-V toolchain / python3）
#   2. 檢查 RTL（../rtl/*.v）。若 RTL 尚未提供，產生「待命」報告後結束。
#   3. 編譯 riscv-tests（rv32ui / rv32um / rv32uc）→ hex
#   4. 以 iverilog 編譯 testbench + RTL，一次編譯、逐個測試執行（tohost 判定）
#   5. 編譯並執行 IPC microbench（mcycle/minstret CSR），解析 IPC
#   6. 產生 REPORT.md
#
# Env 可覆寫：
#   RISCV_CC / RISCV_OBJCOPY / RISCV_NM / RISCV_PREFIX
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$HERE/../rtl"
BUILD="$HERE/build"
TEST_HEX_DIR="$BUILD/tests"
SIM_VVP="$BUILD/sim.vvp"
RESULTS_TSV="$BUILD/results.tsv"
BENCH_TXT="$BUILD/bench.txt"
REPORT="$HERE/REPORT.md"

RISCV_CC="${RISCV_CC:-}"
RISCV_OBJCOPY="${RISCV_OBJCOPY:-}"
RISCV_NM="${RISCV_NM:-}"

# 自動偵測 RISC-V 工具鏈（優先順序）：
#   1. 環境變數 RISCV_CC（已指定則連帶用同前綴的 objcopy/nm）
#   2. 專案自帶 xpack（../tools/xpack-riscv-none-elf-gcc-*/bin）
#   3. PATH 上的 riscv64-unknown-elf-gcc / riscv-none-elf-gcc
if [[ -z "$RISCV_CC" ]]; then
  XPACK_BIN="$(ls -d "$HERE"/../tools/xpack-riscv-none-elf-gcc-*/bin 2>/dev/null | head -1 || true)"
  if [[ -n "$XPACK_BIN" && -x "$XPACK_BIN/riscv-none-elf-gcc" ]]; then
    RISCV_CC="$XPACK_BIN/riscv-none-elf-gcc"
  elif command -v riscv64-unknown-elf-gcc >/dev/null; then
    RISCV_CC="riscv64-unknown-elf-gcc"
  elif command -v riscv-none-elf-gcc >/dev/null; then
    RISCV_CC="riscv-none-elf-gcc"
  fi
fi
if [[ -z "$RISCV_CC" ]]; then
  echo "[run_tests] ERROR: no RISC-V toolchain found." >&2
  echo "  apt: sudo apt-get install gcc-riscv64-unknown-elf" >&2
  echo "  or xpack: see verify/README.md (tools/xpack-riscv-none-elf-gcc-*/bin)" >&2
  exit 1
fi
RISCV_PREFIX="${RISCV_CC%-gcc}"
: "${RISCV_OBJCOPY:=${RISCV_PREFIX}-objcopy}"
: "${RISCV_NM:=${RISCV_PREFIX}-nm}"

log() { echo "[run_tests] $*"; }
die() { echo "[run_tests] ERROR: $*" >&2; exit 1; }

mkdir -p "$BUILD"

# ---------------------------------------------------------------- 1. 工具檢查
log "checking tools..."
# iverilog：PATH 沒有就試專案自帶的 oss-cad-suite
if ! command -v iverilog >/dev/null; then
  OSS_BIN="$(ls -d "$HERE"/../tools/oss-cad-suite/bin 2>/dev/null | head -1 || true)"
  if [[ -n "$OSS_BIN" && -x "$OSS_BIN/iverilog" ]]; then
    export PATH="$OSS_BIN:$PATH"
    log "using project iverilog: $OSS_BIN"
  fi
fi
command -v iverilog >/dev/null || die "iverilog not found (apt install iverilog, or see verify/README.md)"
command -v vvp >/dev/null || die "vvp not found"
command -v python3 >/dev/null || die "python3 not found"
command -v "$RISCV_CC" >/dev/null || die "$RISCV_CC not found"
command -v "$RISCV_OBJCOPY" >/dev/null || die "$RISCV_OBJCOPY not found"
command -v "$RISCV_NM" >/dev/null || die "$RISCV_NM not found"
export RISCV_OBJCOPY RISCV_NM
IVERILOG_VER="$(iverilog -V 2>&1 | head -1)"
GCC_VER="$("$RISCV_CC" --version | head -1)"
log "sim: $IVERILOG_VER"
log "toolchain: $GCC_VER"
"$RISCV_CC" -march=rv32imc_zicsr_zifencei -mabi=ilp32 -E - </dev/null >/dev/null \
  || die "$RISCV_CC does not accept -march=rv32imc_zicsr_zifencei -mabi=ilp32"

# ---------------------------------------------------------------- 2. RTL 檢查
# (exclude tb_*.v testbenches that may live next to the RTL)
RTL_FILES="$(ls "$RTL_DIR"/*.v "$RTL_DIR"/*.sv 2>/dev/null | grep -v '/tb_' || true)"
if [[ -z "$RTL_FILES" ]]; then
  log "RTL not found in $RTL_DIR -- framework is ready, waiting for RTL."
  python3 "$HERE/scripts/gen_report.py" \
    --out "$REPORT" \
    --iverilog-ver "$IVERILOG_VER" \
    --gcc-ver "$GCC_VER" \
    --rtl-status "尚未提供（pending）" \
    --rtl-files ""
  log "wrote $REPORT (pending RTL)"
  exit 2
fi
log "RTL files: $RTL_FILES"

# ---------------------------------------------------------------- 3. 編譯 riscv-tests
if [[ ! -d "$HERE/riscv-tests/isa" ]]; then
  log "cloning riscv-tests..."
  git clone --depth 1 https://github.com/riscv/riscv-tests.git "$HERE/riscv-tests" \
    || die "git clone riscv-tests failed"
fi
log "building riscv-tests hexes..."
RISCV_CC="$RISCV_CC" bash "$HERE/scripts/build_tests.sh"

# ---------------------------------------------------------------- 4. 編譯模擬器
log "compiling testbench + RTL with iverilog..."
# shellcheck disable=SC2086
iverilog -g2012 -o "$SIM_VVP" -s tb_rv32imc \
  "$HERE/tb/tb_rv32imc.v" $RTL_FILES \
  || die "iverilog compile failed"

# ---------------------------------------------------------------- 5. 執行功能測試
log "running ISA tests..."
: > "$RESULTS_TSV"
ntest=0
for hex in "$TEST_HEX_DIR"/*.hex; do
  name="$(basename "$hex" .hex)"
  tohost="$(grep '^tohost=' "$TEST_HEX_DIR/$name.info" | cut -d= -f2 | sed 's/^0x//')"
  out="$(timeout 120 vvp -n "$SIM_VVP" "+hex=$hex" "+tohost=$tohost" 2>&1 || true)"
  if echo "$out" | grep -q "RESULT: PASS"; then
    status="PASS"; detail="$(echo "$out" | grep "RESULT: PASS" | sed 's/.*PASS *//')"
  elif echo "$out" | grep -q "RESULT: FAIL"; then
    status="FAIL"; detail="$(echo "$out" | grep "RESULT: FAIL" | sed 's/.*FAIL *//')"
  else
    status="TIMEOUT"; detail="no tohost write within timeout"
  fi
  printf '%s\t%s\t%s\n' "$name" "$status" "$detail" >> "$RESULTS_TSV"
  ntest=$((ntest + 1))
  if [[ $((ntest % 20)) -eq 0 ]]; then log "  ... $ntest tests done"; fi
done
log "ISA tests done: $ntest"

# ---------------------------------------------------------------- 6. IPC benchmark
log "building IPC microbenchmark..."
BENCH_BUILD="$BUILD/bench"
mkdir -p "$BENCH_BUILD"
# shellcheck disable=SC2086
"$RISCV_CC" -march=rv32imc_zicsr_zifencei -mabi=ilp32 -O2 -static -mcmodel=medany \
  -nostdlib -nostartfiles -T "$HERE/sim.ld" \
  "$HERE/bench/crt0.S" "$HERE/bench/microbench.c" "$HERE/bench/bench_main.c" \
  -lgcc -o "$BENCH_BUILD/bench.elf" || die "bench compile failed"
python3 "$HERE/scripts/elf2hex.py" "$BENCH_BUILD/bench.elf" "$BENCH_BUILD" >/dev/null
BENCH_TOHOST="$(grep '^tohost=' "$BENCH_BUILD/bench.info" | cut -d= -f2 | sed 's/^0x//')"

log "running IPC microbenchmark..."
: > "$BENCH_TXT"
bout="$(timeout 300 vvp -n "$SIM_VVP" \
  "+hex=$BENCH_BUILD/bench.hex" "+tohost=$BENCH_TOHOST" "+timeout=50000000" 2>&1 || true)"
echo "$bout" | sed -n 's/^\[TB\] REPORT id=\([0-9]*\) value=\([0-9]*\).*/REPORT \1 \2/p' >> "$BENCH_TXT"
if echo "$bout" | grep -q "RESULT: PASS"; then
  echo "BENCH_STATUS PASS" >> "$BENCH_TXT"
elif echo "$bout" | grep -q "RESULT: FAIL"; then
  echo "BENCH_STATUS FAIL" >> "$BENCH_TXT"
else
  echo "BENCH_STATUS TIMEOUT" >> "$BENCH_TXT"
fi
# target checksum (id=7, low 24 bits) vs host checksum
tchk="$(grep '^REPORT 7 ' "$BENCH_TXT" | awk '{print $3}')"
if [[ -n "$tchk" ]]; then
  printf 'BENCH_CHECKSUM %06x\n' "$tchk" >> "$BENCH_TXT"
fi
if command -v gcc >/dev/null; then
  gcc -O2 "$HERE/bench/microbench.c" "$HERE/bench/host_main.c" \
    -o "$BENCH_BUILD/microbench_host" 2>/dev/null || true
  if [[ -x "$BENCH_BUILD/microbench_host" ]]; then
    hchk="$("$BENCH_BUILD/microbench_host" | awk '{print $1}')"
    # compare low 24 bits (target only reports 24 bits)
    h24="$(printf '%06x' "$((16#${hchk:2:6}))")"
    echo "HOST_CHECKSUM $h24" >> "$BENCH_TXT"
  fi
fi
log "bench done"

# ---------------------------------------------------------------- 7. 產生報告
python3 "$HERE/scripts/gen_report.py" \
  --results "$RESULTS_TSV" \
  --bench "$BENCH_TXT" \
  --out "$REPORT" \
  --iverilog-ver "$IVERILOG_VER" \
  --gcc-ver "$GCC_VER" \
  --rtl-status "已提供" \
  --rtl-files "$RTL_FILES"
log "wrote $REPORT"
log "ALL DONE"
