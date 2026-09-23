# SYNTH_REPORT.md — rv32imc_top synthesis (sky130hd)

Date: 2026-09-19. Flow: OpenROAD-flow-scripts (master tarball, 2026-09-19) +
Yosys 0.69 + OpenROAD 26Q2-1164-g08f67ee5ec, platform `sky130hd`
(TT_025C_1v80 liberty).

RTL snapshot analysed (md5):
- `alu.v`                a15a523c / 2026-09-19 22:54
- `compressed_decoder.v` cda0ca9b / 2026-09-19 23:08
- `csr.v`                84eb4f55 / 2026-09-19 22:54
- `mul_div.v`            90993cd1 / 2026-09-19 23:09
- `regfile.v`            6d39302d / 2026-09-19 22:54
- `rv32imc_top.v`        e10c81dd / 2026-09-19 23:10

Testbenches (`tb_smoke.v`, `tb_extended.v`) are excluded from synthesis
by the `filter-out` in `design/rv32imc_top/config.mk`.

## Result: PASS (0 errors)

Both runs synthesise cleanly (identical cell count; only the SDC period
differs).

| metric | 8.333 ns (120 MHz probe) | 10.0 ns (100 MHz sign-off) |
|---|---|---|
| stdcells | 21,080 | 21,080 |
| cell area | 193,248 µm² (~0.19 mm²) | 193,248 µm² |
| macros / pads | 0 / 0 (memories are external SRAMs) | 0 / 0 |
| yosys errors | 0 | 0 |
| flow warnings | 2 (benign `STA-0441`: `set_input_delay` on `clk`) | 0 (SDC fixed: clk/rst excluded from data-IO constraints) |
| yosys wall time | ~35 s, peak ~250 MB | ~35 s |

Outputs: `tools/orfs/flow/results/sky130hd/rv32imc_top/base/`
(`1_2_yosys.v`, `1_synth.odb`, `1_synth.sdc`).

## Notes

- The design elaborates cleanly in Yosys; no latches or combinational
  loops inferred (verified by SCC analysis on the mapped netlist).
- The 32×32 regfile is built from discrete flip-flops
  (~1k flops, no SRAM macros) — fine for this size.
- Post-synthesis STA does **not** meet timing — see `TIMING_REPORT.md`.
  Synthesis itself is healthy; the violations are architectural
  (WB→EX→flush long path), not a synthesis-QoR issue.

## Reproduce

```bash
source pnr/env.sh
./pnr/run_synth.sh 8.333   # 120 MHz probe
./pnr/run_synth.sh 10.0    # 100 MHz sign-off target
```
