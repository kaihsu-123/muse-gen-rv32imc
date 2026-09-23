// test_b.s -- always-not-taken branch inside a loop.
//   beq (100x, never taken): BTB never allocates -> always predict NT -> 0 misp.
//   bne loop (100x: 99T + 1NT): cold mispredict + exit mispredict = 2.
// Expected: branches=200, mispredicts=2, checksum t0=0.
#include "common.inc"
    .option norvc
    HDR
    SNAPSHOT s1, s2
    li t0, 100
1:  beq t0, x0, 9f     // never taken: t0 in [100..1]
    addi t0, t0, -1
    bne t0, x0, 1b
9:
    csrr t1, 0x7C0
    csrr t2, 0x7C1
    sub s1, t1, s1
    sub s2, t2, s2
    REPORT 1, s1
    REPORT 2, s2
    REPORT 3, t0
    PASS
    TAIL
