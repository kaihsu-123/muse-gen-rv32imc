# pnr/ — RV32IMC synthesis & P&R

Re-runnable OpenROAD + Sky130 flow for `rv32imc_top`.

## Quick start

```bash
source pnr/env.sh            # once per shell: PATH, LD_LIBRARY_PATH, PDK vars
./pnr/run_synth.sh 8.333     # synthesis + post-synth STA @ 120 MHz probe
./pnr/run_synth.sh 10.0      # synthesis @ 100 MHz sign-off target
./pnr/run_flow.sh 8.333      # full flow: synth → floorplan → place → CTS → route
```

## Layout

| path | what |
|---|---|
| `env.sh` | environment (OpenROAD, Yosys, PDK, volare proxy workaround) |
| `design/rv32imc_top/config.mk` | ORFS design config (sky130hd, `rv32imc_top`) |
| `design/rv32imc_top/constraint.sdc.template` | SDC template; `@CLOCK_PERIOD@` filled by run scripts |
| `design/rv32imc_top/constraint.sdc` | generated per run (do not edit) |
| `run_synth.sh` / `run_flow.sh` | one-command synthesis / full-flow runners |
| `reports/` | per-run logs (`synth_<period>ns.log`, `flow_<period>ns.log`) |
| `SYNTH_REPORT.md` | synthesis results (2026-09-19) |
| `TIMING_REPORT.md` | post-synth timing: **FAIL**, critical-path analysis + RTL recommendations |

Flow artefacts live under `tools/orfs/flow/{results,logs,reports}/sky130hd/rv32imc_top/`
(`base` variant = current RTL; `nobypass` = timing experiment, see timing report).

## Toolchain (all inside the workspace, no root needed)

- PDK: `pdk/volare/sky130/...` (Volare 0.20.6, sky130A commit
  `c6d73a35f524070e85faff4a6a9eef49553ebc2b`); ORFS also vendors the
  essential sky130hd views in `tools/orfs/flow/platforms/sky130hd/`.
- OpenROAD `26Q2-1164-g08f67ee5ec` (Ubuntu 24.04 .deb) +
  OR-Tools 9.14 libs + Ubuntu 22.04→24.04 sysroot debs, see `tools/`.
- Yosys 0.69 from oss-cad-suite (`tools/oss-cad-suite/bin`).
- OpenROAD-flow-scripts master tarball @ 2026-09-19 (`tools/orfs/`).

## Current status (2026-09-19)

- Synthesis: **PASS** — 21,080 cells, 0.19 mm², 0 errors.
- Timing: **FAIL** — WNS −7.67 ns @ 8.33 ns. Critical path is a
  WB→EX→ID chain (`mem_wb_pc` → link_addr → forwarding → ALU →
  branch → flush → ID/EX clock enable). See `TIMING_REPORT.md` for the
  top-10 and concrete RTL fixes. Full P&R deferred until post-synth
  WNS ≥ 0.

## Notes / quirks

- `env.sh` must be sourced (not executed): it sets `LD_LIBRARY_PATH`
  for OpenROAD's OR-Tools libs.
- Volare needs `no_proxy`/`NO_PROXY=localhost,127.0.0.1` (set in `env.sh`);
  the sandbox proxy breaks httpx on IPv6 literals otherwise.
- `config.mk` uses `DESIGN_HOME :=` (immediate) — lazy `=` breaks
  `$(lastword $(MAKEFILE_LIST))` after includes.
- The SDC template keeps a literal `set clk_period <ns>` because ORFS
  parses it with sed for the ABC delay target.
- Machine is 2 cores / 7.7 GB: synthesis ~1 min; full flow will take
  a few hours. Keep `PLACE_DENSITY`/utilization modest.
