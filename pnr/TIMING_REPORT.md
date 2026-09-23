# TIMING_REPORT.md — rv32imc_top post-synthesis STA (sky130hd)

Date: 2026-09-19. Same RTL snapshot / tool versions as `SYNTH_REPORT.md`.
STA: OpenSTA inside OpenROAD 26Q2, TT_025C_1v80, SDC
`pnr/design/rv32imc_top/constraint.sdc` (25 %/25 % IO budget,
0.15 ns setup / 0.05 ns hold uncertainty, `rst_n` false-pathed;
clock and reset excluded from data-IO delay/driver constraints).

Flow note: `pnr/bin/openroad` is a wrapper that sets `LD_LIBRARY_PATH`
for OR-Tools' `libortools.so.9` and the Qt runtime sysroot, because ORFS's
`UNSET_VARS` deliberately clears `LD_LIBRARY_PATH` before invoking
`$(OPENROAD_EXE)`. `env.sh` points `OPENROAD_EXE` at the wrapper.

## Verdict: FAIL — timing does not close at 120 MHz or 100 MHz

| target | WNS | TNS | max achievable* |
|---|---|---|---|
| 8.333 ns (120 MHz, margin probe) | **−7.666 ns** | −1631.86 ns | ~62 MHz |
| 10.0 ns (100 MHz, sign-off) | **−5.999 ns** (measured) | −1217.09 ns | ~62 MHz |

\* Measured at 10 ns: worst path arrival 15.120 ns, required 9.122 ns
(period − 0.150 uncertainty − 0.728 DE-pin setup) → period ≥ 15.998 ns
→ fmax ≈ 62 MHz. Post-layout will be worse (wire delay), not better.

## Top 10 critical paths (10 ns run, measured)

Every violating path starts at the WB-stage PC register and ends at the
**clock-enable (DE) pin** of an ID/EX pipeline register — the pipeline
flush/stall control, not datapath D pins. All ten endpoints share one
combinational cone, hence identical worst slack.

| # | startpoint | endpoint | slack (ns) |
|---|---|---|---|
| 1 | `mem_wb_pc[1]` | `id_ex_alu_op[0]`/DE | −5.9988 |
| 2 | `mem_wb_pc[1]` | `id_ex_alu_op[1]`/DE | −5.9988 |
| 3 | `mem_wb_pc[1]` | `id_ex_alu_op[2]`/DE | −5.9988 |
| 4 | `mem_wb_pc[1]` | `id_ex_alu_op[3]`/DE | −5.9988 |
| 5 | `mem_wb_pc[1]` | `id_ex_b_sel`/DE | −5.9988 |
| 6 | `mem_wb_pc[1]` | `id_ex_csr_addr[0]`/DE | −5.9988 |
| 7 | `mem_wb_pc[1]` | `id_ex_csr_addr[10]`/DE | −5.9988 |
| 8 | `mem_wb_pc[1]` | `id_ex_csr_addr[11]`/DE | −5.9988 |
| 9 | `mem_wb_pc[1]` | `id_ex_csr_addr[1]`/DE | −5.9988 |
| 10 | `mem_wb_pc[1]` | `id_ex_csr_addr[2]`/DE | −5.9988 |

Modules involved (all inside `rv32imc_top`, plus `regfile`):
`rv32imc_top.v` WB stage (link_addr adder) → MEM/WB→EX forwarding muxes →
`alu.v` → branch-compare → `if_flush` → ID/EX clock enables;
`regfile.v` write-bypass contributes a parallel WB→ID path.

## Worst path detail (slack −7.666 ns, arrival 15.120 ns, required 7.455 ns)

```
mem_wb_pc[1]/Q (WB stage PC register)
  → mem_wb_link_addr adder (pc+2/4, ha/fa chain)          ~1.4 ns
  → wb_data mux
  → regfile write-bypass mux  (regfile.v, "helps simulation")
  → ID/EX ... and simultaneously:
  → memwb forwarding mux → fwd_rs1/fwd_rs2 (EX stage)
  → alu.v (32-bit ALU)
  → branch comparator (br_taken_raw)
  → ex_redirect → if_flush
  → id_ex_* /DE  (clock enable of every ID/EX pipeline register)
```

~40 logic levels on one path. Two sub-paths share the head
(`mem_wb_pc → link_addr → wb_data`):
(a) through the **regfile write-bypass** back into ID decode, and
(b) through **MEM/WB→EX forwarding** into the ALU/branch/flush.

Net probe on the worst path (gate `_30300_`, nor2_1, Y pin): its output
net fans out to dozens of load pins (the flush/enable distribution to
all ID/EX DE pins). That single stage accounts for ~8.4 ns of the
15.1 ns arrival — a weak driver on a very high-fanout net, on top of the
long logic chain. Buffering the flush net and/or registering it would
attack both the depth and the fanout components.

## Experiment: regfile write-bypass removed

Re-synthesised with the bypass deleted (scratch copy only, real RTL
untouched; `FLOW_VARIANT=nobypass`):

| variant | WNS @ 8.333 ns | TNS |
|---|---|---|
| as-is (bypass) | −7.666 ns | −1631.86 ns |
| no bypass | −4.180 ns | −928.20 ns |

Removing the bypass helps but the design still fails: path (b) —
`mem_wb_pc → link_addr → wb_data → forwarding → ALU → branch → flush → DE`
— is itself ~12 ns and must close in one cycle.

## Root cause

The WB stage **recomputes** `pc+2/4` (`mem_wb_link_addr`) from `mem_wb_pc`
and that value can forward all the way into the EX-stage branch
comparator and then into the pipeline flush enable — a WB→EX→ID
combinational chain of ~40 levels that cannot meet 8–10 ns in sky130hd.

## Recommendations (for the RTL owner)

1. **Break the WB→forward chain**: carry the already-computed
   `ex_mem_link_addr` through the MEM/WB pipeline register instead of
   recomputing `pc+2/4` in WB. Removes the WB adder from the path.
2. **Remove or gate the regfile write-bypass** (`regfile.v`): it is
   documented as simulation aid; EX-stage forwarding already handles the
   hazard. Saves ~3.5 ns of WNS on its own.
3. If the flush path is still critical, consider resolving branches one
   stage earlier or registering `if_flush` (costs one extra bubble on
   taken branches — an IPC tradeoff to evaluate).
4. Re-run `./pnr/run_synth.sh` after any RTL change; the flow picks up
   `rtl/*.v` automatically (testbenches excluded).

Full P&R (floorplan → detailed route) is set up and ready
(`./pnr/run_flow.sh [period]`) but was intentionally **not** run to
completion: with −7.7 ns WNS at synthesis there is no point burning hours
on P&R until the RTL path above is shortened. Re-run the full flow once
post-synth WNS is ≥ 0.

---

## Post-route STA (2026-09-20, 10ns target, Sky130)

**Flow completed through 6_report** (detail route + fill + final STA).

| Metric | Value |
|---|---|
| Clock period | 10.0 ns (100 MHz target) |
| **Setup WNS** | **-0.02 ns** (2 violating paths) |
| **Setup TNS** | **-0.02 ns** |
| **Hold WNS** | **+0.06 ns** (0 violations) |
| **Critical path** | u_mul.b_r[14] → u_mul.result[19] (multiplier) |
| **Estimated fmax** | **~99.8 MHz** (10.02 ns period) |
| **Design area** | **222,171 µm²** (51% utilization) |

Notes:
- Parasitics: `estimate_parasitics -global_routing` (OpenRCX `set_extraction_rules_file`
  not available in this OpenROAD 26Q2 build; RCX section skipped).
- SETUP_SLACK_MARGIN = -0.050 ns; the -0.02 ns WNS is within the allowed margin.
- DRC has violations (detail route capped at 3 iterations + no antenna-repair loop,
  due to service restarts killing long runs; see STATUS.md).
- 6_final.odb / 6_final.v / 6_final.sdc generated successfully.
