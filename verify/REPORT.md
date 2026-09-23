# RV32IMC CPU 驗證報告 (verify/REPORT.md)

> 產生時間：2026-09-21 18:15 　｜　RTL 狀態：已提供

## 1. 環境

- 模擬器：Icarus Verilog version 12.0 (stable) ()
- RISC-V 工具鏈：riscv-none-elf-gcc (xPack GNU RISC-V Embedded GCC x86_64) 15.2.0（`-march=rv32imc_zicsr_zifencei -mabi=ilp32`）
- RTL 檔案：/home/hatch/workspace/rv32imc-cpu/verify/../rtl/alu.v
/home/hatch/workspace/rv32imc-cpu/verify/../rtl/branch_pred.v
/home/hatch/workspace/rv32imc-cpu/verify/../rtl/compressed_decoder.v
/home/hatch/workspace/rv32imc-cpu/verify/../rtl/csr.v
/home/hatch/workspace/rv32imc-cpu/verify/../rtl/mul_div.v
/home/hatch/workspace/rv32imc-cpu/verify/../rtl/regfile.v
/home/hatch/workspace/rv32imc-cpu/verify/../rtl/rv32imc_top.v
- 測試來源：riscv-tests（rv32ui / rv32um / rv32uc，physical `-p-` 測試）

## 2. 功能測試結果

- 總數：51　｜　PASS：51　｜　FAIL：0　｜　TIMEOUT：0

| 測試 | 結果 | 說明 |
|---|---|---|
| rv32uc-p-rvc | PASS | after 340 cycles |
| rv32ui-p-add | PASS | after 684 cycles |
| rv32ui-p-addi | PASS | after 397 cycles |
| rv32ui-p-and | PASS | after 729 cycles |
| rv32ui-p-andi | PASS | after 336 cycles |
| rv32ui-p-auipc | PASS | after 146 cycles |
| rv32ui-p-beq | PASS | after 492 cycles |
| rv32ui-p-bge | PASS | after 517 cycles |
| rv32ui-p-bgeu | PASS | after 594 cycles |
| rv32ui-p-blt | PASS | after 492 cycles |
| rv32ui-p-bltu | PASS | after 540 cycles |
| rv32ui-p-bne | PASS | after 496 cycles |
| rv32ui-p-fence_i | PASS | after 789 cycles |
| rv32ui-p-jal | PASS | after 143 cycles |
| rv32ui-p-jalr | PASS | after 237 cycles |
| rv32ui-p-lb | PASS | after 423 cycles |
| rv32ui-p-lbu | PASS | after 453 cycles |
| rv32ui-p-ld_st | PASS | after 1415 cycles |
| rv32ui-p-lh | PASS | after 440 cycles |
| rv32ui-p-lhu | PASS | after 443 cycles |
| rv32ui-p-lui | PASS | after 151 cycles |
| rv32ui-p-lw | PASS | after 447 cycles |
| rv32ui-p-ma_data | PASS | after 651 cycles |
| rv32ui-p-or | PASS | after 736 cycles |
| rv32ui-p-ori | PASS | after 353 cycles |
| rv32ui-p-sb | PASS | after 772 cycles |
| rv32ui-p-sh | PASS | after 791 cycles |
| rv32ui-p-simple | PASS | after 119 cycles |
| rv32ui-p-sll | PASS | after 732 cycles |
| rv32ui-p-slli | PASS | after 387 cycles |
| rv32ui-p-slt | PASS | after 666 cycles |
| rv32ui-p-slti | PASS | after 384 cycles |
| rv32ui-p-sltiu | PASS | after 384 cycles |
| rv32ui-p-sltu | PASS | after 666 cycles |
| rv32ui-p-sra | PASS | after 783 cycles |
| rv32ui-p-srai | PASS | after 419 cycles |
| rv32ui-p-srl | PASS | after 786 cycles |
| rv32ui-p-srli | PASS | after 416 cycles |
| rv32ui-p-st_ld | PASS | after 706 cycles |
| rv32ui-p-sub | PASS | after 679 cycles |
| rv32ui-p-sw | PASS | after 841 cycles |
| rv32ui-p-xor | PASS | after 781 cycles |
| rv32ui-p-xori | PASS | after 346 cycles |
| rv32um-p-div | PASS | after 373 cycles |
| rv32um-p-divu | PASS | after 403 cycles |
| rv32um-p-mul | PASS | after 780 cycles |
| rv32um-p-mulh | PASS | after 801 cycles |
| rv32um-p-mulhsu | PASS | after 813 cycles |
| rv32um-p-mulhu | PASS | after 831 cycles |
| rv32um-p-rem | PASS | after 367 cycles |
| rv32um-p-remu | PASS | after 409 cycles |

## 3. IPC 量測（microbench，mcycle / minstret CSR）

目標：overall IPC ≥ 0.65

- benchmark 執行狀態：TIMEOUT
- checksum 比對（target vs host）：不一致 ❌ (target=, host=92e57e)

| # | 項目 | IPC |
|---|---|---|
| 1 | ALU + predictable branches (base CPI) | 0.662 |
| 2 | unpredictable branches (branch penalty) | 0.645 |
| 3 | load-use chains (load-use penalty) | 0.572 |
| 4 | multiply chains (M-extension) | 0.391 |
| 5 | mixed workload | n/a |
| 6 | overall (whole run) | n/a |

## 4. Stall 來源分析

判讀方式（各 microbench 隔離單一 stall 來源）：

- bench 1（ALU）量出 base CPI；理想 5-stage forwarding 設計應接近 1.0。
- bench 2 vs bench 1 的差距 ≈ branch mispredict penalty × mispredict rate。若差距大，檢查 branch predictor / flush 代價（幾個 bubble）。
- bench 3 vs bench 1 的差距 ≈ load-use stall。若大，檢查 load-use hazard detection 是否多 stall 了不需要的情況，或 forwarding 路徑。
- bench 4 反映 M-extension 實作：若 mul 是多 cycle 未 pipeline，IPC 會明顯掉；考慮改為 pipelined multiplier 或 early-out。
- bench 5（mixed）是最接近真實程式的值；若它明顯低於 bench 1，代表綜合的 hazard/stall 邏輯還有優化空間。

（RTL 實測後在此填入具體數據與結論。）

## 5. DUT 介面契約

見 `verify/README.md`：`rv32imc_top` 的 clk/rst_n、imem/dmem Harvard bus（single-cycle），以及 tohost pass/fail 協定。
