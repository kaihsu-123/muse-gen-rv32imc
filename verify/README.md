# verify/ — RV32IMC CPU 功能驗證環境

## 一鍵執行

```bash
cd ~/workspace/rv32imc-cpu/verify
./run_tests.sh
```

流程：工具檢查 → RTL 檢查 → 編譯 riscv-tests（rv32ui/um/uc）→ iverilog 編譯
testbench + RTL → 逐個測試執行（tohost 判定 pass/fail）→ IPC microbench →
產生 `REPORT.md`。

RTL 尚未提供時，腳本會產生「待命」報告並以 exit code 2 結束。

## 目錄

| 路徑 | 說明 |
|---|---|
| `run_tests.sh` | 一鍵執行腳本 |
| `REPORT.md` | 測試報告（由腳本產生） |
| `sim.ld` | bare-metal linker script（程式連結在 0x0，128 KiB） |
| `tb/tb_rv32imc.v` | testbench：載入 hex、tohost 監控、timeout 看門狗 |
| `scripts/build_tests.sh` | 編譯 riscv-tests → `.elf` → `.hex` + `.info` |
| `scripts/elf2hex.py` | ELF → `$readmemh` hex，並用 nm 找出 tohost 位址 |
| `scripts/gen_report.py` | 由測試結果產生 REPORT.md |
| `bench/` | IPC microbench（crt0.S、microbench.c、bench_main.c、host_main.c） |
| `riscv-tests/` | riscv-tests 原始碼（執行時自動 clone） |
| `build/` | 編譯產物（hex、vvp、結果檔） |

## DUT 介面契約（RTL 設計者請看這裡）

頂層模組必須命名為 **`rv32imc_top`**。目前 `../rtl/rv32imc_top.v` 的實際介面如下
（testbench 的 `ADAPTER` 區段已對應此介面；若 RTL 變更介面，請同步修改
`tb/tb_rv32imc.v` 的 `ADAPTER` 區段）。

```verilog
module rv32imc_top (
    input  wire        clk,
    input  wire        rst_n,       // 低電位有效 reset
    // Instruction memory (Harvard, combinational read, 無 re 訊號)
    output wire [31:0] imem_addr,  // byte address
    input  wire [31:0] imem_rdata,
    // Data memory (Harvard)
    output wire        dmem_en,     // bus enable
    output wire [31:0] dmem_addr,  // byte address
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,  // byte strobes；全 0 = read
    input  wire [31:0] dmem_rdata,
    // debug 觀察用
    output wire [31:0] dbg_pc,      // WB 級的 PC
    output wire [31:0] dbg_instr,   // WB 級的指令
    output wire        dbg_valid
);
```

testbench 假設 **single-cycle** 的記憶體（組合邏輯讀、時脈寫入）。

額外需求：

- Reset 向量 = `0x00000000`（程式從 0x0 開始執行）。
- 必須實作 CSR `mtvec`、`mcause`、`mepc`、`mstatus`（trap 機制用），
  以及 `mcycle`（0xB00）、`minstret`（0xB02）（IPC benchmark 用 `csrr` 讀取）。
- **未實作 CSR 的寫入必須被忽略、不可 trap**：riscv-tests 的啟動程式
  （`env/p/riscv_test.h`）會寫入 `pmpaddr0`、`pmpcfg0`、`medeleg`、`mideleg`、
  `satp`、`MNSTATUS` 等 CSR。若 CPU 對未實作的 CSR 寫入產生
  illegal-instruction trap，所有測試會在初始化階段 FAIL（testnum=668）。
  不想忽略的話，就把這些 CSR 實作出來（PMP 可設為全開）。

## tohost 協定（riscv-tests 新版 test-env）

測試以 `ecall`（a7=93）結束，trap handler 將 `gp`（TESTNUM）寫入 `tohost`：

| 寫入值 | 意義 |
|---|---|
| `1` | PASS |
| `(testnum << 1) \| 1` | FAIL（testnum = 值 >> 1） |
| `(id << 24) \| value`（id≠0） | benchmark 回報（id 見 bench/microbench.c），繼續執行 |

testbench 監控對 `tohost` 位址的 32-bit store 來判定結果；
handler 隨後對 `tohost+4` 的寫入（結束標記）會被忽略。

`tohost` 位址由 `elf2hex.py` 用 `nm` 從每個 `.elf` 抓出，存在 `.info` 檔，
`run_tests.sh` 以 `+tohost=` plusarg 傳給模擬器。

若 RTL 的 bus 介面與契約不同，請只改 `tb/tb_rv32imc.v` 中標示 `ADAPTER` 的區段。

## IPC benchmark 設計

`bench/microbench.c` 內含 5 個隔離 stall 來源的 microbench，
各別用 `mcycle`/`minstret` 量 IPC（定點回報 `IPC×1000`）：

1. ALU + 可預測分支 → base CPI
2. 不可預測分支 → branch mispredict penalty
3. load-use 相依鏈 → load-use stall
4. 乘法鏈 → M-extension 延遲/吞吐
5. 混合 workload（近似 dhrystone 風格）
6. 整體 IPC（目標 ≥ 0.65）
7. checksum（與 host 交叉比對，驗證功能正確性）

## 環境需求

- `iverilog`（`apt install iverilog`；或專案自帶 `../tools/oss-cad-suite/bin`）
- RISC-V 工具鏈（`run_tests.sh` 自動偵測，優先順序）：
  1. 環境變數 `RISCV_CC` 指定的編譯器；
  2. 專案自帶 xpack：`../tools/xpack-riscv-none-elf-gcc-*/bin/riscv-none-elf-gcc`
     （已下載 v15.2.0，`run_tests.sh` 會自動使用）；
  3. `PATH` 上的 `riscv64-unknown-elf-gcc`（Ubuntu `apt install
     gcc-riscv64-unknown-elf`）或 `riscv-none-elf-gcc`。
- 旗標：`-march=rv32imc_zicsr_zifencei -mabi=ilp32`
  （GCC 13+ 需顯式 `_zicsr` 才能用 CSR 指令、`_zifencei` 才能用 `fence.i`）
- `python3`、`git`、`gcc`（host，編譯 checksum 比對程式用）

### 手動安裝 xpack（若需重裝）

```bash
cd ~/workspace/rv32imc-cpu/tools
VER=15.2.0-1
curl -L -o xpack-riscv-none-elf-gcc-${VER}-linux-x64.tar.gz \
  https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${VER}/xpack-riscv-none-elf-gcc-${VER}-linux-x64.tar.gz
tar xzf xpack-riscv-none-elf-gcc-${VER}-linux-x64.tar.gz
# run_tests.sh 會自動偵測到 ../tools/xpack-riscv-none-elf-gcc-*/bin
```
