// test_pred_alive.S -- predictor liveness / degradation check.
// A 1000-iteration always-taken loop must show ~2 mispredicts and a low
// cycle count. This FAILS if the predictor is silently disabled
// (static not-taken: 1000 mispredicts, ~+2000 cycles) or the SRAM read
// path is broken (stale/wrong predictions -> excess mispredicts).
#include "common.inc"
    .option norvc
    HDR
    SNAPSHOT s1, s2
    csrr t0, mcycle
    li t1, 1000
1:  addi t1, t1, -1
    bne t1, x0, 1b
    csrr t2, mcycle
    csrr t3, 0x7C0          # branches resolved
    csrr t4, 0x7C1          # mispredicts
    sub t3, t3, s1          # expect 1000
    sub t4, t4, s2          # expect 2
    sub t0, t2, t0          # cycles
    REPORT 1, t0
    REPORT 2, t4
    REPORT 3, t3
    li t5, 1000
    bne t3, t5, fail        # branch count sanity
    li t5, 10
    bgt t4, t5, fail        # too many mispredicts -> predictor broken
    li t5, 3000
    bgt t0, t5, fail        # too slow -> predictions not helping
    PASS
fail:
    li t5, (93 << 1) | 1
    sw t5, 0(s0)
9:  j 9b
    TAIL
