# RV32IMC 5-Stage Pipelined CPU

5 級管線、支援 RV32I + M + C 的 RISC-V CPU，plain Verilog-2001（Yosys 可綜合），
目標 Sky130 上 100MHz+。

## Pipeline

```
        ┌────┐  ┌────┐  ┌────┐  ┌────┐  ┌────┐
        │ IF │→ │ ID │→ │ EX │→ │MEM │→ │ WB │
        └────┘  └────┘  └────┘  └────┘  └────┘
                  ↑       ↑
             C-decompress forwarding
             hazard detect (EX/MEM, MEM/WB)
```

- **IF**: PC 暫存器；每週期取 32-bit，ID 判斷是否為 16-bit 壓縮指令（PC+2/+4）。
- **ID**: C 解壓縮 → 完整 32-bit 指令；暫存器讀取；控制訊號產生；
  load-use hazard 偵測、CSR RAW 偵測。
- **EX**: ALU、分支/跳轉解析（mispredict 時 2-cycle penalty；詳見下方分支預測器）、
  M 擴展（乘法器 2-cycle pipeline、除法器 ~35 cycles，管線 stall 等待）、
  CSR 讀寫、trap 偵測（illegal/ecall/ebreak）。
- **MEM**: 資料記憶體存取（byte/half/word，sign/zero extend）。
- **WB**: 寫回暫存器；`minstret` 計數。

## 檔案

| 檔案 | 說明 |
|---|---|
| `rv32imc_top.v` | 頂層：管線、forwarding、hazard、控制邏輯 |
| `alu.v` | ALU（ADD/SUB/SLL/SRL/SRA/XOR/OR/AND/SLT/SLTU） |
| `regfile.v` | 32x32 暫存器，2 讀 1 寫，x0 恆零 |
| `csr.v` | CSR：mstatus/mie/mtvec/mscratch/mepc/mcause/mtval/mip、mcycle(h)/minstret(h)；trap/mret 處理 |
| `compressed_decoder.v` | RV32C 解壓縮（ID 階段） |
| `mul_div.v` | 2-stage pipeline 乘法器（MUL/MULH/MULHSU/MULHU）；多週期恢復式除法器（DIV/DIVU/REM/REMU，~35 cycles，含除零與 INT_MIN/-1 處理） |
| `tb_smoke.v` | smoke testbench（ALU/load-store/branch/JAL/MUL-DIV/CSR/trap/mret） |

## 介面

```verilog
module rv32imc_top (
    input  wire        clk,
    input  wire        rst_n,        // 非同步 assert
    output wire [31:0] imem_addr,    // 指令記憶體位址
    input  wire [31:0] imem_rdata,   // 單週期組合邏輯讀取
    output wire        dmem_en,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,   // byte strobe；全 0 表讀取
    input  wire [31:0] dmem_rdata,   // 單週期組合邏輯讀取
    output wire [31:0] dbg_pc,       // WB 階段 PC（供 testbench 觀察）
    output wire [31:0] dbg_instr,
    output wire        dbg_valid
);
```

I/D 記憶體分開，皆為單週期 SRAM 風格（組合邏輯讀取）。合成時需接 SRAM macro 或
改為同步讀取（需調整管線）。

## 執行 smoke test

```bash
cd rtl
iverilog -g2005 -o tb_smoke.vvp tb_smoke.v rv32imc_top.v alu.v regfile.v \
    csr.v compressed_decoder.v mul_div.v
vvp tb_smoke.vvp   # 預期: SMOKE TEST PASSED
```

## 分支預測器（`branch_pred.v`）

- Bimodal：512-entry BHT（2-bit saturating counter，`PC[10:2]` index，
  reset 為 weakly not-taken）＋ 64-entry BTB（`PC[7:2]` index，
  `PC[31:8]` tag）。
- IF 查表；BTB hit 且 BHT ≥ 2 才預測 taken。Mispredict 走原有 EX
  redirect/flush；正確預測的 taken path 不 flush。
- BTB target 存 `PC[31:1]`（RVC 16-bit 指令的 target bit 1 可能為 1，
  存 `[31:2]` 會壞掉）。
- 自訂唯讀 CSR：`0x7C0`（resolved 分支/跳轉數）、`0x7C1`（mispredict 數）。
- 驗證報告：`verify/PREDICTOR_VERIF.md`；directed tests：
  `verify/pred_tests/`。

## 已知限制

- Bimodal 對 period-2 的分支 pattern（如 taken/not-taken 交替）幾乎 100%
  mispredict；BTB 僅 64 entries，working set 大會 thrash。
- 未實作 misaligned load/store trap（假設對齊存取）。
- 無 F/D/A 擴展；無中斷控制器（`mip_in` 接 0，僅 machine-mode trap）。
- `fence`/`fence.i` 視為 NOP。
- 除法器 latency ~35 cycles；乘法器關鍵路徑為 32x32 乘法器本體，
  若 Sky130 timing 不過可再拆成 partial-product 兩級。
