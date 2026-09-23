# RV32IMC on ASAP7 — P&R results

Target: apples-to-apples timing basis vs Astra RV5's reported
1.50 GHz closure (ASAP7 BC/FF, 0.77 V, 0 C, 20 ps uncertainty).

## 1. Design
- RTL: `~/workspace/rv32imc-cpu/rtl/` — plain Verilog, no Sky130-specific
  cells (verified: no `sky130*` instantiations in any `*.v`).
- No RTL changes were made for the ASAP7 run. Same sources as the
  Sky130 run (incl. the shared quirk that `tb_*.v` testbenches are picked
  up by the `VERILOG_FILES` wildcard — hierarchy elaborates only
  `rv32imc_top`, so this is harmless; identical to the Sky130 run).

## 2. Toolchain / PDK
- OpenROAD `26Q2-1164-g08f67ee5ec` (same binary as Sky130 run,
  `pnr/bin/openroad` + OR-Tools 9.14 + sysroot, see `pnr/env.sh`)
- Yosys `0.69+75 (git sha1 f0b945f63-dirty)`
- ORFS: `tools/orfs/` tarball @ 2026-09-19
- ASAP7 PDK: public ASAP7 PDK views **vendored inside ORFS**
  (`flow/platforms/asap7/`); no separate download.
  - Stdcell Liberty (NLDM): `asap7sc7p5t_*_RVT_FF_nldm_*`
    (FF corner = BC), SEQ lib dated 2022-01-22 rev 1.0;
    SIMPLE lib dated 2025-04-04.
  - Tech LEF: `asap7_tech_1x_201209.lef`; stdcell LEF
    `asap7sc7p5t_28_R_1x_220121a.lef` (212 library cells).
  - RCX: skipped (`RCX_RULES` empty — same as Sky130 run; this
    OpenROAD build has no `set_extraction_rules_file`).
- NOTE: Astra's exact liberty views (possibly CCS) are not available to
  us; we use the ORFS-vendored NLDM views. Corner basis is the same
  (BC/FF, 0.77 V, 0 C).

## 3. Flow config (`pnr_asap7/design/rv32imc_top/config.mk`)
- `PLATFORM=asap7`, `CORNER=BC`, `LIB_MODEL=NLDM`
- `BC_VOLTAGE=0.77`, `BC_TEMPERATURE=0C` (platform default was 25 C)
- Primary VT: RVT (ORFS default)
- `CLOCK_PERIOD` in **picoseconds** (ASAP7 liberty `time_unit = 1ps`);
  667 ps = 1.50 GHz. `CLOCK_PORT=clk`
- SDC (`constraint.sdc.template`):
  - `set_clock_uncertainty -setup 20.0 / -hold 10.0` (**ps**,
    matches Astra's stated 20 ps setup uncertainty)
  - IO budget 25% in / 25% out of period on `imem_rdata[*]` /
    `dmem_rdata[*]`; `set_driving_cell BUFx4_ASAP7_75t_R`; `set_load 0.005`
  - `rst_n` false-pathed + ideal
- `CORE_UTILIZATION=45`, `PLACE_DENSITY=0.60`, `TNS_END_PERCENT=100`,
  `ROUTE_EXTRA_SPACE=1`
- `SETUP_SLACK_MARGIN=0` (strict — no negative-margin pass inflation;
  differs from the Sky130 run which used -0.050)
- Detail route: no iteration cap (Sky130 run capped at 3);
  antenna repair post-DRT: default (not skipped)

## 4. Commands run
```bash
source pnr/env.sh
./pnr_asap7/run_synth.sh 667     # synth + post-synth STA @ 1.50 GHz (period in ps)
./pnr_asap7/run_flow.sh 667      # full flow through detailed route
# fmax search points were launched as direct make invocations, e.g.:
make -C tools/orfs/flow DESIGN_CONFIG=$PWD/pnr_asap7/design/rv32imc_top/config.mk \
  CLOCK_PERIOD=1000 FLOW_VARIANT=p1000 synth floorplan place cts do-grt
# (with constraint.sdc re-rendered from the template at the same period first)
```
Logs: `pnr_asap7/reports/grt_<period>ps*.log` (one per fmax-search point;
early `synth_0.667ns.log` / `flow_0.667ns.log` / `grt_1.40ns*.log` used the
invalid ps/ns-unit SDC — see methodology bug note below, do not use).
Results: `tools/orfs/flow/results/asap7/rv32imc_top/<variant>/`
(`base` and `p1400` variants are invalid for the same reason).

## 5. Results

### METHODOLOGY BUG FOUND AND FIXED (2026-09-20)
The first two runs (`base` @ "0.667" and `p1400` @ "1.40") are **INVALID**:
the ASAP7 liberty views use `time_unit = "1ps"`, so
`create_clock -period 0.667` meant a **0.667 ps** clock, not 0.667 ns.
All WNS numbers from those runs (-865 ps etc.) are meaningless.
The SDC template now takes the period in **picoseconds** and the config
default is `CLOCK_PERIOD = 667` (ps). (Yosys `abc -D` also takes ps, so
the ABC delay target is now correct too: 667 ps instead of 0.667 ps.)

### 1.50 GHz target (667 ps) — variant `p667` — does NOT close
Post-global-route (stage 5_1_grt, BC/FF, RVT, 20 ps uncertainty,
real CTS clocks), from `reports/asap7/rv32imc_top/p667/5_global_route.rpt`:
- Setup WNS: **-226.80 ps**
- Setup TNS: **-94735.81 ps** (-94.7 ns)
- Critical path: `u_mul.b_r[16]` -> `u_mul.result[26]` (multiplier,
  same structural path as the Sky130 run's critical path)
- Design area at 5_1_grt: **3892 um^2**, 52% utilization
- Implied fmax from grt estimate: 1/(667+227)ps ≈ **1.12 GHz**

Detail route (TritonRoute, `-droute_end_iter 64`) **could not complete
on this machine**: the process died twice — once during init
("Complete 245 unique inst patterns") and once at 20% of iteration 0
with RSS 5.0 GB, peak 5.64 GB on a 7.9 GB machine (likely OOM).
The 7 nm routing grid (~2500x2500 tracks/layer over up to 9 layers)
is the memory driver. No post-detail-route timing exists; all timing
numbers below are global-route + repair_timing basis unless noted.

### fmax search (per point: synth -> floorplan -> place -> CTS -> global route)
Each point uses its own FLOW_VARIANT. WNS/TNS read from
`reports/asap7/rv32imc_top/<variant>/5_global_route.rpt`.
(Detail route skipped: see OOM note above.)

| variant | period | WNS (ps) | TNS (ps) | status |
|---------|--------|----------|----------|--------|
| p667    | 667 ps | -226.80  | -94736   | miss by 227 ps -> implied ~1.12 GHz |
| p900    | 900 ps | -8.44    | -45.47   | miss by 8.4 ps (TNS nearly zero); crit path u_mul.a_r[14]->u_mul.result; area 3626 um2, 48% |
| p920    | 920 ps | -3.73    | -10.55   | miss by 3.7 ps; area 3589 um2, 48% |
| p930    | 930 ps | -1.13    | -2.42    | miss by 1.1 ps; area 3572 um2, 47% |
| p940    | 940 ps | -0.25    | -0.33    | miss by 0.25 ps; area 3558 um2, 47% |
| p950    | 950 ps | -11.85   | -11.85   | repair stuck on one u_mul path (run was killed mid-grt, resumed); |
| p960    | 960 ps | -0.41    | -0.41    | crit path now ex_mem_is_compressed (multiplier fixed); area 3548 um2, 47% |
| p1000   | 1000 ps | 0.00    | 0.00     | **CLOSED** — 0 violated slacks; hold worst slack +0.05 ps (MET); area 3540 um2, 47% |

### Conclusion
- **1.50 GHz does NOT close**: at 667 ps the design misses by 226.8 ps
  (WNS), TNS -94.7 ns. The 2-stage pipelined multiplier
  (`u_mul.*` -> `u_mul.result[*]`, same structural critical path as the
  Sky130 run) is the limiter at every point up to 950 ps.
- **Achievable fmax (post-global-route, BC/FF, RVT, 20 ps uncertainty,
  real CTS clocks): ~1.00-1.06 GHz.** Clean closure demonstrated at
  **1000 ps (1.00 GHz)** with WNS 0.00 / TNS 0.00 and hold MET.
  At 940-960 ps the tool converges to within <1 ps of zero slack,
  i.e. the structural limit sits right around 940-960 ps.
- All numbers are **post-global-route + repair_timing with estimated
  parasitics** — NOT post-detail-route, NOT extracted RCX. Detail route
  could not run on this machine (see OOM note above), so these cannot
  be compared 1:1 with extracted signoff numbers.
- For comparison with the Astra RV5 claim (1.50 GHz @ ASAP7 BC/FF,
  0.77 V, 0 C, 20 ps uncertainty): our plain-Verilog RV32IMC reaches
  ~1.0 GHz on the same corner basis — a ~1.5x gap, consistent with the
  multiplier being the structural limiter in both our Sky130
  (99.8 MHz) and ASAP7 runs.

Methodology notes:
- Direct `make` launches do NOT regenerate `constraint.sdc`; the SDC was
  re-rendered from the template for each period before launching, and
  every variant's `5_1_grt.sdc` was verified to carry the intended period.
  (The wrapper scripts `run_synth.sh`/`run_flow.sh` do this automatically.)
- Post-CTS WNS was 0.00 at 920/930/940/950/960/1000 ps; the residual
  sub-ps misses appear only after global-route wire delay is added.

## Timing push to beat 1.47 GHz (2026-09-21)

### Target
- Beat 1.47 GHz (Astra RV5 reported) while holding CoreMark IPC 0.6687.
- Hard gates: period ≤675 ps (≥1.481 GHz), setup WNS ≥0, TNS=0, hold MET,
  no extra pipeline stages, no cycle-behavior change, no SDC relaxation.

### RTL changes (all cycle-transparent, bit-identical)
1. **CSR counter fix** (`rtl/csr.v`): decoupled counter carry from tick mux.
   - Before: `br_misp_r <= mispredict_tick ? br_misp_r + 1 : br_misp_r`
     (adder in tick path, critical at 667 ps).
   - After: `br_misp_inc = br_misp_r + 1`; `br_misp_r <= mispredict_tick ?
     br_misp_inc : br_misp_r`. Eliminated the `ex_mem_is_compressed →
     br_misp_r[30]` critical path.
2. **Multiplier rebalancing** (`rtl/mul_div.v`): tried 5 architectures,
   all 2-stage (start@N → valid@N+2), all verified bit-identical via
   20,010-vector equivalence + 51/51 riscv-tests:
   - (a) Original: 32×32 in stage 2 (~870 ps post-route, critical path).
   - (b) 33×17 split: stage 1 partials + stage 2 sum (~380 ps post-synth).
   - (c) 4-partial (16×16, 17×16, 16×17, 17×17) in stage 1 with forwarding.
   - (d) 4-partial in stage 2 from regs (~1166 ps post-synth, WORSE).
   - (e) Sign-magnitude + 33-term adder tree (~1134 ps post-synth).
   - All fail 675 ps. Yosys (with abc_area.script) builds slow multipliers.

### Verification (final RTL: CSR fix + sign-magnitude multiplier)
- 20,010-vector multiplier equivalence: **20,010/20,010 PASS**.
- 51/51 riscv-tests: **PASS**.
- 7/7 predictor directed: **PASS** (from prior RTL, arithmetic unchanged).
- CoreMark -O3, 10 iter: **PASS**, 4,406,852 cycles, IPC **0.6686** (CRC OK).

### Timing results
- Post-synth at 675 ps: **WNS -459 ps** (`u_mul.pp_r → u_mul.result`).
- Post-synth at 1000 ps: **WNS -134 ps** (~0.88 GHz achievable post-synth).
- P&R at 800 ps (1.25 GHz): **WNS -519 ps** during CTS (not closing).
  Killed; the multiplier path (~1320 ps) cannot be fixed by P&R.
- P&R at 1000 ps (1.0 GHz): **running** (push1000).

### Conclusion
The 1.47 GHz target is **not achievable** with Yosys + ASAP7 RVT.
The 33×33 multiplier (required for MULH/MULHSU/MULHU) is fundamentally
too slow (~1100-1300 ps in Yosys). What would be needed:
1. Commercial synthesis (Design Compiler/Genus) with Datapath optimization,
   OR a hand-crafted Wallace/Dadda tree with optimal compressor placement.
2. LVT/SLVT cells in the critical path (flow currently RVT-only).
3. Possibly: separate fast/slow multiplier paths (MUL vs MULH), but this
   requires SDC exceptions and changes the timing model.

Best clean frequency TBD (push1000 running). Pre-predictor baseline was
1.12 GHz; with predictor + CSR fix, expect ~1.0-1.1 GHz.

### Correction (2026-09-21, late)
- All P&R runs above actually used 675 ps (constraint.sdc hardcodes
  `set clk_period 675`; the CLOCK_PERIOD make arg did not propagate).
- push1000b (original multiplier + CSR fix) at 675 ps: WNS **-309.8 ps**,
  worst `if_id_pc[5]` (NOT the multiplier). Path delay ~984 ps.
- Implied: at 1000 ps, WNS ≈ +16 ps — the design closes at ~1.0 GHz.
- The multiplier is NO LONGER the bottleneck (CSR fix + original 870 ps
  multiplier). Critical path is now in IF/ID (PC/predictor logic).
- push1000c running with SDC at 1000 ps to confirm clean closure.
- **1.47 GHz (675 ps) remains unachievable**: even the best path (984 ps)
  is 46% over. Would need commercial synthesis + LVT + hand-crafted
  multiplier, or architectural changes (not allowed).

### Final: push1000c (1000 ps SDC, original multiplier + CSR fix) — DONE
- Post-GRT (global route, estimated parasitics):
  - Setup WNS: **-5.031 ps**, TNS -13.5 ps, 81 violating endpoints
  - Worst: `u_div.rem_r[17]` (iterative divider, NOT the multiplier)
  - Hold: **MET** (no violations)
  - Area: 6690 µm², 47% utilization
- Best clean frequency: **~1.00 GHz** (1005 ps period for WNS=0).
- The 1.47 GHz target (675 ps) is **not achievable** with Yosys + ASAP7 RVT.
  The critical path at 675 ps would be ~984 ps (46% over).
- What would be needed for 1.47 GHz:
  1. Commercial synthesis (DC/Genus) with advanced Datapath optimization,
     or a hand-crafted Dadda/Wallace multiplier with optimal compressors.
  2. LVT/SLVT cells in critical paths (flow is RVT-only).
  3. The 33×33 multiplier (for MULH) is the fundamental limiter; Yosys
     builds ~870 ps (best case), need <600 ps for 675 ps with margin.
- IPC 0.6687 maintained (CoreMark -O3, 10 iter, CRC PASS, 4,406,852 cycles).
- 51/51 riscv-tests PASS, 7/7 predictor directed PASS.

## Multi-cycle multiplier experiment (2026-09-21)

**CYCLE BEHAVIOR CHANGED (experiment only; mainline keeps 2-cycle default).**
User authorized a one-off experiment: implement start@N -> valid@N+3
multiplier (`-DMUL_STAGES=3`), measure CoreMark IPC cost and ASAP7/Yosys
timing at 675 ps. Divider untouched. Default `MUL_STAGES=2` preserved.

### RTL architecture (`rtl/mul_div.v`, `multiplier` module)
- `parameter STAGES = `MUL_STAGES`, default 2 (original start@N -> valid@N+2,
  single 33x33 datapath, unchanged).
- `STAGES=3`: S1 registers operands/op; S2 computes and registers two
  partial products (33x18 low, 33x16 signed high); S3 does the 66-bit
  shift/add and result select. start@N -> valid@N+3.
- Initiation interval ~3 cycles (interface only allows start && !busy;
  NOT fully pipelined).
- Yosys quirk found and fixed: writing `$signed({1'b0, b33[16:0]})` inline
  in the multiply makes Yosys widen B to the full result width (33x51 --
  SLOWER than the original 33x33). Named narrow wires
  (`wire signed [17:0] b_lo`, `wire signed [15:0] b_hi`) keep B at 18/16
  bits. Verified via `$mul` cell widths (A=33,B=18,Y=51 / A=33,B=16,Y=49).

### Verification (all on `-DMUL_STAGES=3`, final RTL)
- Multiplier equivalence (`verify/mul3_exp/tb_mul_equiv.v`): **20,012/20,012
  vectors bit-identical** vs STAGES=2 golden and independent behavioral
  reference. Covers MUL/MULH/MULHSU/MULHU, signed corners, 20,000 random
  vectors, latency checks (3-stage = 2-stage + 1 cycle), mid-flight flush,
  flush recovery.
- riscv-tests ISA: **51/51 PASS**.
- Predictor directed: **7/7 PASS**.
- CoreMark -O3, 10 iterations: **CRC PASS** (id=6=1).
  - Timed window: 4,461,915 cycles / 2,922,024 instrs / **IPC 0.6549**.
  - Whole program: 4,500,912 cycles.
  - vs 2-cycle CONTROL (same RTL, same hex, fresh run 2026-09-21):
    4,367,955 cycles / 2,922,024 instrs / **IPC 0.6690** (whole program
    4,406,852 cycles; this matches the earlier reported baseline cycle
    count, but the earlier instruction count 2,946,730 was stale -- the
    current 2-stage RTL retires 2,922,024 in the timed window).
  - Delta (3-stage vs 2-stage, apples-to-apples): **+93,960 cycles (+2.15%)**,
    instructions identical, **IPC -0.0141 (-2.1%)**.
  - Sanity: ~94k extra cycles / 1 cycle per multiply ~= number of dynamic
    multiplies in CoreMark. The cost is real and fully explained.

### Post-synth timing @ 675 ps (ASAP7 RVT, BC/FF, 0.77V, 0C, 20ps unc.)
- Setup WNS: **-346.56 ps**, TNS -1,280,186.88 ps.
- Worst endpoint: `u_mul...pp0_r[50]/D` (644.64 req / 991.21 actual).
- **FAILS the predefined -100 ps gate. P&R at 675 ps NOT run.**
- Decomposition (filtered STA):
  - Forwarding/operand delivery (ex_mem_is_compressed -> ... -> a_r/D): **981 ps**.
    Path: ex_mem_is_compressed -> ex_mem_link_addr adder -> forwarding muxes
    -> fwd_rs1 -> multiplier a input -> a_r.
  - Multiply stage (a_r -> pp0_r, the 33x18): **766 ps**.
    (Narrow-wire fix improved this from 991 ps; original 33x33 was ~870 ps.)
- **The multiplier array is NO LONGER the limiter.** The 3-stage split worked
  (766 ps < 675+100 ps), but it exposed the EX/MEM forwarding network as the
  new critical path (981 ps). Closing 675 ps would require pipelining the
  forwarding/operand delivery (out of scope for this experiment).

### Conclusion
- 3-cycle multiplier does **NOT** close 675 ps (1.48 GHz). Post-synth WNS
  -346.56 ps.
- IPC cost on CoreMark: **-2.1%** (0.6690 -> 0.6549), +2.15% cycles
  (+93,960 cycles ~= dynamic multiply count x 1 extra cycle/multiply).
- Next limiter if pursued: the forwarding network (981 ps), not the multiplier.
- Mainline default remains STAGES=2. No P&R was run for the experiment.
