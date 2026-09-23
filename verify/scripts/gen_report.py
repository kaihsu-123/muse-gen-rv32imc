#!/usr/bin/env python3
"""gen_report.py -- generate verify/REPORT.md from test run artifacts.

Usage:
    gen_report.py --results results.tsv --bench bench.txt --out REPORT.md
                  --iverilog-ver "..." --gcc-ver "..." [--rtl-status ...]

results.tsv : tab-separated lines: <test-name>\\t<PASS|FAIL|TIMEOUT>\\t<detail>
bench.txt   : lines produced by the bench run:
                  REPORT <id> <ipc_x1000>
                  BENCH_CHECKSUM <hex>      (target-reported, low 24 bits)
                  HOST_CHECKSUM  <hex>      (host cross-check)
                  BENCH_STATUS   <PASS|FAIL|TIMEOUT>
"""
import argparse
import datetime
import os

BENCH_NAMES = {
    1: "ALU + predictable branches (base CPI)",
    2: "unpredictable branches (branch penalty)",
    3: "load-use chains (load-use penalty)",
    4: "multiply chains (M-extension)",
    5: "mixed workload",
    6: "overall (whole run)",
}
IPC_TARGET = 0.65


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="")
    ap.add_argument("--bench", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--iverilog-ver", default="n/a")
    ap.add_argument("--gcc-ver", default="n/a")
    ap.add_argument("--rtl-status", default="unknown")
    ap.add_argument("--rtl-files", default="")
    a = ap.parse_args()

    tests = []
    if a.results and os.path.exists(a.results):
        with open(a.results) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                tests.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))

    bench_reports = {}
    bench_status = "NOT RUN"
    bench_checksum = ""
    host_checksum = ""
    if a.bench and os.path.exists(a.bench):
        with open(a.bench) as f:
            for line in f:
                p = line.split()
                if not p:
                    continue
                if p[0] == "REPORT" and len(p) == 3:
                    bench_reports[int(p[1])] = int(p[2]) / 1000.0
                elif p[0] == "BENCH_STATUS":
                    bench_status = p[1]
                elif p[0] == "BENCH_CHECKSUM":
                    bench_checksum = p[1]
                elif p[0] == "HOST_CHECKSUM":
                    host_checksum = p[1]

    npass = sum(1 for _, s, _ in tests if s == "PASS")
    nfail = sum(1 for _, s, _ in tests if s == "FAIL")
    ntimeout = sum(1 for _, s, _ in tests if s == "TIMEOUT")
    ntotal = len(tests)

    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M %Z")
    L = []
    L.append("# RV32IMC CPU 驗證報告 (verify/REPORT.md)")
    L.append("")
    L.append(f"> 產生時間：{now}　｜　RTL 狀態：{a.rtl_status}")
    L.append("")
    L.append("## 1. 環境")
    L.append("")
    L.append(f"- 模擬器：{a.iverilog_ver}")
    L.append(f"- RISC-V 工具鏈：{a.gcc_ver}（`-march=rv32imc_zicsr_zifencei -mabi=ilp32`）")
    L.append(f"- RTL 檔案：{a.rtl_files or '（尚未提供）'}")
    L.append("- 測試來源：riscv-tests（rv32ui / rv32um / rv32uc，physical `-p-` 測試）")
    L.append("")
    L.append("## 2. 功能測試結果")
    L.append("")
    if ntotal == 0:
        L.append("尚未執行（RTL 未到齊或測試尚未編譯）。")
    else:
        L.append(f"- 總數：{ntotal}　｜　PASS：{npass}　｜　FAIL：{nfail}　｜　TIMEOUT：{ntimeout}")
        L.append("")
        L.append("| 測試 | 結果 | 說明 |")
        L.append("|---|---|---|")
        for name, status, detail in tests:
            L.append(f"| {name} | {status} | {detail} |")
    L.append("")
    L.append("## 3. IPC 量測（microbench，mcycle / minstret CSR）")
    L.append("")
    L.append(f"目標：overall IPC ≥ {IPC_TARGET}")
    L.append("")
    if bench_status == "NOT RUN":
        L.append("尚未執行（等待 RTL）。")
    else:
        L.append(f"- benchmark 執行狀態：{bench_status}")
        if bench_checksum or host_checksum:
            match = "一致 ✅" if (bench_checksum and bench_checksum == host_checksum) else "不一致 ❌"
            L.append(f"- checksum 比對（target vs host）：{match} "
                     f"(target={bench_checksum}, host={host_checksum})")
        L.append("")
        L.append("| # | 項目 | IPC |")
        L.append("|---|---|---|")
        for i in sorted(BENCH_NAMES):
            v = bench_reports.get(i)
            cell = f"{v:.3f}" if v is not None else "n/a"
            mark = ""
            if i == 6 and v is not None:
                mark = " ✅ 達標" if v >= IPC_TARGET else " ❌ 未達標"
            L.append(f"| {i} | {BENCH_NAMES[i]} | {cell}{mark} |")
    L.append("")
    L.append("## 4. Stall 來源分析")
    L.append("")
    L.append("判讀方式（各 microbench 隔離單一 stall 來源）：")
    L.append("")
    L.append("- bench 1（ALU）量出 base CPI；理想 5-stage forwarding 設計應接近 1.0。")
    L.append("- bench 2 vs bench 1 的差距 ≈ branch mispredict penalty × mispredict rate。"
              "若差距大，檢查 branch predictor / flush 代價（幾個 bubble）。")
    L.append("- bench 3 vs bench 1 的差距 ≈ load-use stall。若大，檢查 load-use "
              "hazard detection 是否多 stall 了不需要的情況，或 forwarding 路徑。")
    L.append("- bench 4 反映 M-extension 實作：若 mul 是多 cycle 未 pipeline，"
              "IPC 會明顯掉；考慮改為 pipelined multiplier 或 early-out。")
    L.append("- bench 5（mixed）是最接近真實程式的值；若它明顯低於 bench 1，"
              "代表綜合的 hazard/stall 邏輯還有優化空間。")
    L.append("")
    L.append("（RTL 實測後在此填入具體數據與結論。）")
    L.append("")
    L.append("## 5. DUT 介面契約")
    L.append("")
    L.append("見 `verify/README.md`：`rv32imc_top` 的 clk/rst_n、imem/dmem "
             "Harvard bus（single-cycle），以及 tohost pass/fail 協定。")
    L.append("")

    with open(a.out, "w") as f:
        f.write("\n".join(L))
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
