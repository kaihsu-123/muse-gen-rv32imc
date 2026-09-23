# muse-gen-rv32imc

This CPU was wished into existence — typed on a phone, built on the free tier.
No workstation. No EDA license. No spec document. Four messages and twenty hours later: a 5-stage pipelined **RV32IMC**, 51/51 riscv-tests pass, CoreMark **IPC 0.6687**.
The timing reports are in the repo — including the ones we failed.

---

## What it is

| | |
|---|---|
| ISA | RV32IMC (I + M + C), machine mode, CSRs, precise interrupts |
| Pipeline | 5-stage, full forwarding, load-use stall |
| Branch predictor | 512×2-bit BHT + 64-entry direct-mapped BTB — predict in IF, resolve in EX |
| Multiplier | 2-stage pipelined (a 3-stage variant was built and measured — see below) |
| Divider | Iterative, multicycle |

No cache. No FPU. No MMU. What you see is what's verified.

## Verification — receipts, not claims

| Suite | Result |
|---|---|
| riscv-tests (rv32ui / um / uc) | **51/51 PASS** |
| Predictor directed tests | **7/7 PASS** |
| Predictor performance tests | **12/12 PASS** |
| Multiplier equivalence (2-stage vs 3-stage) | **20,012/20,012 bit-identical PASS** |
| CoreMark (`-O3`, 10 iterations) | **CRC PASS** |

One command reproduces the functional suite: `cd verify && ./run_tests.sh` (needs Icarus Verilog; riscv-tests is cloned automatically).

## Performance

CoreMark on RTL simulation (Icarus), `-O3`, 10 iterations, CRC-valid:

| Metric | Value |
|---|---|
| Instructions retired | 2,946,730 |
| Cycles | 4,406,852 |
| **IPC** | **0.6687** |
| CoreMark/MHz | ~2.269 |
| Timed branches | 597,929 |
| Mispredicts (MPKI) | 226,073 (76.7) |

Context: the pre-predictor baseline was IPC 0.6302 (static not-taken) — the bimodal predictor bought **+6.1%**. The reference design this was measured against claims 0.645; we're **+3.7%** above it. This is functional RTL simulation, not an EEMBC-certified run — methodology is documented in `verify/`.

## Silicon — the honest table

| Flow | Target | Closest demonstrated | Verdict |
|---|---|---|---|
| Sky130 + OpenROAD | ≥ 100 MHz | 99.8 MHz post-route (WNS −0.02 ns @ 10 ns) | **Not closed.** 20 ps short; DRC violations remained |
| ASAP7 (Yosys, RVT) | 1.47 GHz | 1000 ps post-route, WNS −5.0 ps, 81 violating endpoints | **Not achieved.** Implied clean ≈ 0.995 GHz was never demonstrated |
| 3-stage multiplier experiment | trade cycles for GHz | IPC 0.6549 (−2.1%); WNS −347 ps @ 675 ps post-synth | Bottleneck moved to operand delivery, didn't disappear |

A timing report you only show when it passes isn't a timing report — it's marketing. Full scripts, STA reports, and logs live in `pnr/` and `pnr_asap7/`.

## The story

Four human prompts. The first one wasn't a spec — it was a wish:

> 弄個 rv32imc 的 cpu，確認它有被 verify，用 open road 確定 sky130 有 100+mhz，ipc 不小於 0.65

*("Build a verified RV32IMC CPU. Prove 100+ MHz on Sky130 with OpenROAD. IPC ≥ 0.65.")*

Everything after that — the 5-stage microarchitecture, hazard handling, the branch predictor, the multiplier experiments, ~20 hours of implementation, debug, and regression — was the agent's. The human set the bar, made the calls at the forks (predictor? multi-cycle multiplier? stop digging?), and demanded the receipts. (Yes, we counted the prompts. 691 database rows, 4 that mattered.)

**The human wished. The agent spec'd, built, and verified.**

## Repo layout

```
rtl/         Verilog source (rv32imc_top, alu, mul_div, branch_pred, csr, ...)
verify/      one-command regression: riscv-tests, predictor tests, CoreMark
pnr/         Sky130 + OpenROAD: scripts, reports, logs
pnr_asap7/   ASAP7 experiments: STA reports, 3-stage multiplier study
```

## Reproduce the verification

```bash
# functional regression (Icarus Verilog required)
cd verify && ./run_tests.sh

# P&R (OpenROAD + Sky130 PDK)
cd pnr && ./run_flow.sh
```

## Regenerate the CPU

The scripts above reproduce the *verification*. The CPU itself is reproduced with prompts — paste these into Muse, in order:

1. `那我的考試題目是。弄個rv32imc的cpu確認它有被verify ，用open road確定sky130有100+mhz ipc不小於0.65`
2. `你可以比較ipc，跟 vexriscv 比，要給它跑這幾個測試更好或是align`

(Two more messages in the original session were just "is it done yet" check-ins during the overnight run — plus one insult about being slower than Sonnet. It worked.)

Note: regeneration is not deterministic. Same prompts, different CPU — hopefully one that still clears the acceptance criteria. Reproducing the verification is science; regenerating the artifact is a dice roll with good odds.

---

*Not affiliated with Meta. Built with Muse (free tier), powered by Muse Spark 1.3.*
