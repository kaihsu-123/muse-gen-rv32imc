#!/usr/bin/env python3
"""check_perf.py -- validate branch-predictor PERFORMANCE characterization tests.

Two layers:
  1. An INDEPENDENT Python model of the documented predictor algorithm
     (BTB: 64-entry direct-mapped, idx PC[7:2], tag PC[31:8];
      BHT: 512 x 2-bit, idx PC[10:2], reset 1 = weakly not-taken;
      BTB miss -> predict not-taken; BHT trains on every resolving CF insn;
      BTB allocates on taken CF only) is run over each test's exact branch
     trace. Measured CSR deltas must match the model EXACTLY.
  2. For the fuzz tests, the measured steady-state mispredict rate is compared
     against the closed-form theory of a 2-bit saturating counter driven by an
     i.i.d. taken-probability-p source (4-state Markov chain, solved below).

Usage: check_perf.py <build_dir>
"""
import os
import re
import sys
import random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_perf_tests import ITERS, WORDS, J_SEEDS

# ---------------------------------------------------------------- model
def btb_idx(pc):
    return (pc >> 2) & 63


def btb_tag(pc):
    return (pc >> 8) & 0xFFFFFF


def bht_idx(pc):
    return (pc >> 2) & 511


def simulate(events):
    """events: iterable of (pc, taken). Returns (branches, mispredicts,
    per_pc_mispredicts dict). Direct transcription of branch_pred.v."""
    btb = {}   # idx -> tag
    bht = {}   # idx -> counter, default 1 (weakly not-taken)
    br = misp = 0
    per_pc = {}
    for pc, taken in events:
        i, t, h = btb_idx(pc), btb_tag(pc), bht_idx(pc)
        hit = btb.get(i) == t
        pred = hit and bht.get(h, 1) >= 2
        if pred != taken:
            misp += 1
            per_pc[pc] = per_pc.get(pc, 0) + 1
        br += 1
        c = bht.get(h, 1)
        bht[h] = min(c + 1, 3) if taken else max(c - 1, 0)
        if taken:
            btb[i] = t
    return br, misp, per_pc


# ---------------------------------------------------------------- traces
# All PCs are relative (base-independent); only index/tag differences matter.
def trace_h(n):
    ev = []
    for it in range(ITERS):
        for i in range(n - 1):
            ev.append((4 * (i + 1), True))
        ev.append((4 * n, it < ITERS - 1))      # loop branch
    return ev


def trace_h7():
    # NOTE: the loop-back `bne` spans -16132B, beyond the B-type +/-4KiB
    # range, so the assembler emits `beqz` (skip the jump on exit) + `jal`
    # (unconditional jump back). Both are control-flow and both are modeled:
    # beqz @16132 (BTB idx 1) taken only on the last iteration, jal @16136
    # (BTB idx 2) always taken. Neither shares a BTB/BHT index with the
    # kernel (idx 0) or with each other.
    nker = 63
    beqz_pc = 256 * nker + 4
    jal_pc = 256 * nker + 8
    ev = []
    for it in range(ITERS):
        for i in range(nker):
            ev.append((256 * i, True))
        ev.append((beqz_pc, it == ITERS - 1))
        if it < ITERS - 1:
            ev.append((jal_pc, True))
    return ev


def trace_i1():
    ev = []
    for it in range(ITERS):
        for i in range(32):
            ev.append((8 * i, True))            # always taken
            ev.append((8 * i + 4, False))       # never taken
        ev.append((260, it < ITERS - 1))        # loop branch
    return ev


def trace_i2():
    ev = []
    for it in range(ITERS):
        for i in range(32):
            ev.append((4 * i, True))            # taken
        for i in range(32):
            ev.append((2048 + 4 * i, False))   # never taken, same BHT entry
        ev.append((2180, it < ITERS - 1))       # loop branch
    return ev


def fuzz_words(p):
    rng = random.Random(J_SEEDS[p])
    words = []
    for _ in range(WORDS):
        w = 0
        for k in range(32):
            w |= (0 if rng.random() < p else 1) << k
        words.append(w)
    return words


def trace_j(p):
    words = fuzz_words(p)
    ev = []
    for w in range(WORDS):
        for k in range(32):
            bit = (words[w] >> k) & 1
            ev.append((8, bit == 0))            # random branch @ inner+8
            ev.append((20, k < 31))             # inner loop branch @ inner+20
        ev.append((28, w < WORDS - 1))          # outer loop branch @ inner+28
    return ev


# ---------------------------------------------------------------- theory
def theory_mispredict_rate(p):
    """Steady-state mispredict rate of a 2-bit saturating counter with
    i.i.d. taken probability p. States 0..3 (SN,WN,WT,ST), predict taken
    iff state >= 2. Balance: pi1 = r*pi0, pi2 = r^2*pi0, pi3 = r^3*pi0
    with r = p/q; M = (pi2+pi3)*q + (pi0+pi1)*p."""
    q = 1.0 - p
    r = p / q
    pi0 = 1.0 / (1 + r + r * r + r * r * r)
    return (r * r + r * r * r) * pi0 * q + (1 + r) * pi0 * p


# ---------------------------------------------------------------- main
def parse(log_path):
    rep = {}
    passed = False
    with open(log_path) as f:
        for line in f:
            m = re.search(r"REPORT id=(\d+) value=(\d+)", line)
            if m:
                rep[int(m.group(1))] = int(m.group(2))
            if "RESULT: PASS" in line:
                passed = True
    return rep, passed


def check_exact(name, build, trace, extra=""):
    log = os.path.join(build, f"test_{name}.log")
    if not os.path.exists(log):
        return f"{name}: MISSING LOG", False
    rep, passed = parse(log)
    exp_br, exp_misp, _ = simulate(trace())
    got = (rep.get(1), rep.get(2), rep.get(3))
    ok = passed and got[0] == exp_br and got[1] == exp_misp
    rate = got[1] / got[0] if got[0] else 0
    detail = (f"branches={got[0]} (model {exp_br}) "
              f"mispredicts={got[1]} (model {exp_misp}) "
              f"rate={rate:.4f} cksum={got[2]}{extra}")
    return f"{name}: {'OK ' if ok else 'FAIL'} pass={passed} {detail}", ok


def check_fuzz(name, build, p):
    tag = name
    log = os.path.join(build, f"test_{tag}.log")
    if not os.path.exists(log):
        return [f"{tag}: MISSING LOG"], False
    rep, passed = parse(log)
    words = fuzz_words(p)
    ones = sum(bin(w).count("1") for w in words)
    n = 32 * WORDS
    taken = n - ones
    exp_br, exp_misp, per_pc = simulate(trace_j(p))
    got_br, got_misp, got_t6 = rep.get(1), rep.get(2), rep.get(3)
    lines = []
    ok = True

    # 1. table integrity: t6 must equal the seeded popcount exactly
    t6ok = passed and got_t6 == ones
    ok &= t6ok
    lines.append(f"{tag}: t6(popcount)={got_t6} (seed {J_SEEDS[p]}: {ones}) "
                 f"{'OK' if t6ok else 'FAIL'}")

    # 2. RTL must match the independent model exactly
    mok = passed and got_br == exp_br and got_misp == exp_misp
    ok &= mok
    lines.append(f"{tag}: branches={got_br} (model {exp_br}) "
                 f"mispredicts={got_misp} (model {exp_misp}) "
                 f"{'OK' if mok else 'FAIL'}")

    # 3. model self-consistency: inner/outer loop branches contribute
    #    exactly WORDS+1 / 2 mispredicts (validates the accounting model)
    inner_m = per_pc.get(20, 0)
    outer_m = per_pc.get(28, 0)
    cok = (inner_m == WORDS + 1) and (outer_m == 2)
    ok &= cok
    lines.append(f"{tag}: nonrandom mispredicts inner={inner_m} "
                 f"(exp {WORDS + 1}) outer={outer_m} (exp 2) "
                 f"{'OK' if cok else 'FAIL'}")

    # 4. measured random-branch rate vs 2-bit-counter theory
    rand_misp = got_misp - (WORDS + 3)
    rate = rand_misp / n
    theory = theory_mispredict_rate(p)
    emp_p = taken / n
    rok = abs(rate - theory) <= 0.03 and abs(emp_p - p) <= 0.02
    ok &= rok
    lines.append(f"{tag}: P(taken)={p} empirical={emp_p:.4f} "
                 f"rand_mispredict_rate={rate:.4f} theory={theory:.4f} "
                 f"diff={abs(rate - theory):.4f} {'OK' if rok else 'FAIL'}")
    return lines, ok


def main():
    build = sys.argv[1]
    allok = True
    print("== BTB capacity sweep (h1..h7): model-exact ==")
    for name, n in [("h1", 16), ("h2", 32), ("h3", 64),
                    ("h4", 96), ("h5", 128), ("h6", 256)]:
        msg, ok = check_exact(name, build, lambda n=n: trace_h(n))
        print(msg)
        allok &= ok
    msg, ok = check_exact("h7", build, trace_h7)
    print(msg)
    allok &= ok

    print("== BHT aliasing (i1/i2): model-exact ==")
    for name, tr in [("i1", trace_i1), ("i2", trace_i2)]:
        msg, ok = check_exact(name, build, tr)
        print(msg)
        allok &= ok

    print("== randomized fuzz vs theory (j1..j3) ==")
    for name, p in [("j1", 0.1), ("j2", 0.5), ("j3", 0.9)]:
        lines, ok = check_fuzz(name, build, p)
        for line in lines:
            print(line)
        allok &= ok

    print("ALL PASS" if allok else "FAILURES PRESENT")
    sys.exit(0 if allok else 1)


if __name__ == "__main__":
    main()
