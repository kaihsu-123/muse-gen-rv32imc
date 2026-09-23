# Branch Predictor — Verification Report

Date: 2026-09-21. Core: RV32IMC 5-stage, Icarus functional sim.

## 1. What was built

A **bimodal branch predictor** (chosen as the simpler option) was added to the
previously predictor-less core:

- **BHT**: 512 × 2-bit saturating counters, flop-based, index `PC[10:2]`,
  reset to weakly not-taken (`2'b01`).
- **BTB**: 64 entries, flop-based, index `PC[7:2]`, tag `PC[31:8]`.
- IF-stage combinational lookup. Predict taken iff BTB hit **and** BHT
  counter ≥ 2; predicted target comes from the BTB.
- BHT trains on every resolving control-flow instruction toward the actual
  outcome (including toward not-taken on a false-positive prediction).
- BTB allocates/overwrites on taken control-flow instructions.
- Mispredicts reuse the existing EX redirect/flush path. All three cases are
  handled: direction mismatch, target mismatch (JALR target change, BTB
  halfword aliasing), and false-positive prediction on a non-control
  instruction (redirects to fall-through; the instruction still retires).
- Custom read-only CSRs: `0x7C0` = control-flow instructions resolved,
  `0x7C1` = mispredictions. Both count exactly-once per EX resolution
  (suppressed while mul/div stalls or MEM holds).

**Spec deviation (documented, intentional):** the BTB stores the target as
`PC[31:1]`, not `PC[31:2]`. RVC branch/jump targets are 2-byte aligned, so
bit 1 of a target can be 1 (target at an odd halfword). Storing only
`PC[31:2]` would corrupt every such predicted target (off by 2). Test G
below directly proves bit 1 is preserved.

## 2. Directed predictor tests (7/7 pass)

`verify/pred_tests/` — each test snapshots `0x7C0`/`0x7C1` around a tight
kernel and checks the deltas against hand-computed expectations. Run with
`run_pred_tests.sh`, checked with `check_pred.py`.

| Test | Kernel | Branches (exp/got) | Mispredicts (exp/got) | Checksum |
|---|---|---|---|---|
| a | always-taken loop ×100 | 100 / 100 | 2 / 2 | t0=0 |
| b | never-taken branch in loop ×100 | 200 / 200 | 2 / 2 | t0=0 |
| c | alternating T/N/T/N… ×200 | 400 / 400 | 202 / 202 | t4=100 |
| d | nested loops 10×20 | 210 / 210 | 13 / 13 | t0\|t1=0 |
| e | JALR alternating two targets ×10 | 25 / 25 | 13 / 13 | t0=0 |
| f | BTB halfword aliasing: 16-bit taken branch at even halfword, 16-bit non-branch at odd halfword of same word → false-positive prediction must flush to fall-through | 3 / 3 | 4 / 4 | a1=1 |
| g | JALR to odd-halfword target ×3 (proves BTB preserves target bit 1; the bit-1-dropping bug would give 7 mispredicts, not 5) | 8 / 8 | 5 / 5 | t1=0 |

Test c is the honest-weakness case: a 2-bit counter cannot learn a
period-2 pattern, so it mispredicts ~100% of the alternating branches
(200/200 on that branch). This is expected bimodal behavior, not a bug.

**Bug found by these tests:** the first version of the EX redirect computed
`ex_actual_target = br_target` unconditionally, so a *not-taken* branch that
was predicted taken redirected to the branch target instead of the
fall-through — an infinite loop (tests a/c/d/e hung; test b showed one
extra branch + mispredict). Fixed by making the not-taken actual target
`PC + (is_compressed ? 2 : 4)`. All 7 tests pass after the fix.

## 3. ISA regression

`verify/run_tests.sh` (riscv-tests, predictor enabled): **51/51 PASS**.

## 4. CoreMark performance (-O3, 10 iterations)

Timed sources (`core_list_join.c`, `core_matrix.c`, `core_state.c`,
`core_util.c`, `core_main.c`) are **unmodified** (md5-verified). Port-layer
`start_time()`/`stop_time()` additionally snapshot `0x7C0`/`0x7C1`; the
deltas are reported as tohost ids 12–15. Memory model unchanged
(combinational single-cycle 128 KiB).

| Metric | Value |
|---|---|
| Timed cycles | 4,406,852 |
| Timed instructions | 2,946,730 |
| Timed branches (0x7C0 Δ) | 597,929 |
| Timed mispredicts (0x7C1 Δ) | 226,073 |
| Mispredict rate | 37.8% (226,073 / 597,929) |
| Mispredicts per kilo-instruction (MPKI) | 76.7 |
| IPC (timed) | **0.6687** (2,946,730 / 4,406,852) |
| CoreMark/MHz (synthetic from cycles) | 2.27 (10 iter × 1e6 / 4,406,852 cycles) |
| CRC | PASS (tohost=1) |

Baseline (no predictor): IPC **0.6302** (4,636,892 cycles / 2,922,018
instrs). Target: 0.645.

**Result: PASS — IPC 0.6687 beats the 0.645 target (+6.1% over baseline
0.6302).** The predictor saves 230,040 cycles (~5.0%) on the timed region
despite a 37.8% mispredict rate; the 62.2% correctly-predicted branches
avoid the 2-cycle flush penalty.

**Bug found during CoreMark (fixed):** a pipeline control bug, not a
predictor bug. When a BTB false-positive (non-branch predicted taken) was
detected in EX in the *same cycle* as a load-use stall
(`load_use_stall=1`), the `pc_stall` blocked the `pc` update, losing the
`ex_redirect`. IF/ID and ID/EX were still flushed, so the next fetch used a
stale pc — executing and retiring an instruction from the wrong address,
corrupting the architectural state (CoreMark list benchmark walked a wrong
list pointer). Fixed by giving `if_flush` (redirect/trap/mret) priority
over `pc_stall` in the `pc` update:
`else if (if_flush) pc <= pc_next; else if (!pc_stall) pc <= pc_next;`.
The stalled instruction is on the flushed (wrong) path, so ignoring the
stall on redirect is safe. All 7 directed tests, 51 ISA tests, and CoreMark
pass after the fix.

## 5. Caveats

- The predictor is bimodal; workloads with period-2 branch patterns will see
  ~100% mispredicts on those branches (test c). No gshare/history.
- BTB is 64 entries, direct-mapped by `PC[7:2]`; larger working sets will
  thrash it (measured: §6). BHT is 512 entries; destructive aliasing is
  possible (measured: §6).
- The `0x7C0` delta includes the `ret` from `start_time()` itself (one extra
  counted branch, constant across builds).
- This is functional (Icarus) verification only — no timing/P&R impact
  measured in this task.

## 6. Performance characterization (12 tests, all pass)

`verify/pred_tests/gen_perf_tests.py` generates the tests,
`run_perf_tests.sh` builds/runs them, and `check_perf.py` validates them in
two independent layers:

1. **Independent Python model** of the documented algorithm (BTB: 64-entry
   direct-mapped, `PC[7:2]`, tag `PC[31:8]`; BHT: 512×2-bit, `PC[10:2]`,
   reset weakly-not-taken; BTB miss → predict not-taken; BHT trains on every
   resolving CF insn; BTB allocates on taken CF only). Every test's CSR
   deltas must match the model **exactly** — any single-count deviation is
   a failure.
2. **Closed-form theory** for the fuzz tests (2-bit saturating counter as a
   4-state Markov chain; derivation below).

### 6a. BTB capacity / thrash sweep (h1–h7)

N always-taken branches + loop branch, 200 iterations, all with distinct
BHT entries so only the BTB is stressed:

| Test | N taken branches | BTB occupancy | Branches | Mispredicts (model=RTL) | Mispred. rate |
|---|---|---|---|---|---|
| h1 | 16 | 17 ≤ 64, no conflict | 3,200 | 17 | 0.53% |
| h2 | 32 | 33 ≤ 64, no conflict | 6,400 | 33 | 0.52% |
| h3 | 64 | 64 = capacity, no conflict | 12,800 | 65 | 0.51% |
| h4 | 96 | 97 > 64, pairwise conflicts | 19,200 | 12,831 | 66.8% |
| h5 | 128 | 129 > 64, pairwise conflicts | 25,600 | 25,599 | 100.0% |
| h6 | 256 | 257 > 64, 4-way conflicts | 51,200 | 51,199 | 100.0% |
| h7 | 63 | all 63 share ONE index (256 B stride) | 12,999 | 12,602 | 97.0% |

The capacity cliff is sharp and exactly as modeled: at N≤64 every branch
pays only its cold miss (N+1 mispredicts); past 64 entries the
direct-mapped BTB thrashes and the mispredict rate jumps to 67–100%.
h7 shows the conflict case at small N: 63 branches colliding on a single
index mispredict 97% of the time.

(Test artifact, documented: h7's loop-back `bne` spans −16132 B, beyond the
B-type ±4 KiB range, so the assembler emits `beqz`+`jal`. Both are modeled
in `check_perf.trace_h7`; the beqz/jal BTB/BHT indices are asserted
distinct from the kernel's.)

### 6b. BHT destructive aliasing (i1, i2)

| Test | Kernel | Branches | Mispredicts (model=RTL) | Mispred. rate |
|---|---|---|---|---|
| i1 | 32 always-taken + 32 never-taken, all 64 on distinct BHT entries | 13,000 | 34 | 0.26% |
| i2 | same 64 branches, but each T/N pair shares one BHT entry (2048 B stride) | 13,000 | 6,402 | 49.3% |

i1 is the control: no aliasing, only cold misses (34 = 32×1 + loop 2).
i2 is the destructive-aliasing case: two branches with opposite outcomes
fighting over one 2-bit counter keep it pinned in the middle, mispredicting
essentially every execution (6,400 of the 6,402 mispredicts are the aliased
pair). Delta i2−i1 = 6,368 extra mispredicts from aliasing alone.

### 6c. Seeded randomized fuzz vs 2-bit-counter theory (j1–j3)

16,384 branch outcomes from fixed seeds (checked-in tables; no PRNG on
target), popcount checksum in `s3` (REPORT clobbers `t5/t6`, so the checksum
cannot live in `t6`) verified exactly against the seed:

| Test | P(taken) | Seed | Empirical P(taken) | Checksum (exp/got) | Random-branch mispred. rate (meas.) | Theory |
|---|---|---|---|---|---|---|
| j1 | 0.1 | 12345 | 0.1035 | 14,688 / 14,688 | 0.1136 | 0.1098 |
| j2 | 0.5 | 67890 | 0.5012 | 8,173 / 8,173 | 0.5030 | 0.5000 |
| j3 | 0.9 | 13579 | 0.9001 | 1,637 / 1,637 | 0.1105 | 0.1098 |

All three also match the independent model exactly on total
branches/mispredicts (33,280 / 2,376 / 8,756 / 2,325), and the
non-random loop branches contribute exactly 513 + 2 mispredicts as the
model predicts — validating the accounting, not just the total.

**Theory derivation.** A 2-bit saturating counter driven by an i.i.d.
taken-probability-`p` source is a 4-state Markov chain (states 0..3 =
SN/WN/WT/ST; predict taken iff state ≥ 2). With `q=1−p` and `r=p/q`,
balance gives `π_i ∝ r^i`; the steady-state mispredict rate is
`M(p) = p(π_0+π_1) + q(π_2+π_3) = pq/(p²+q²)`.
Hence M(0.1)=M(0.9)=0.09/0.82≈0.1098 and M(0.5)=0.5. Measured rates agree
within 0.004 (statistical σ ≈ 0.0024 at n=16,384).

**Test bug found by the checker (fixed, in-test only):** the first j-test
kept its popcount checksum in `t6`, but the REPORT macro uses `t6` as
scratch — so `REPORT 1`/`REPORT 2` destroyed the checksum before
`REPORT 3` read it (it reported the mispredict count instead of 14,688).
Fixed by accumulating the checksum in `s3` (callee-saved, untouched by
REPORT). The checker now verifies the checksum exactly.

**Test/model discrepancy found and resolved (in-test only):** h7 initially
reported 199 more branches than the naive model. Root cause: the
assembler's `beqz`+`jal` expansion of the out-of-range loop `bne`
(verified in objdump), not an RTL bug. The model was corrected to include
both instructions; RTL and model now agree exactly (12,999 / 12,602).
