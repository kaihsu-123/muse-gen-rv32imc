// test_a.s -- always-taken loop (100 iterations).
// Hand-computed expectation:
//   iter 1: BTB miss -> predict NT, actual T -> mispredict (cold). BHT 01->10.
//   iters 2..99: BTB hit, BHT>=2 -> predict T, actual T -> correct.
//   iter 100 (exit): predict T, actual NT -> mispredict.
// Expected: branches=100, mispredicts=2, checksum t0=0.
#include "common.inc"
    .option norvc
    HDR
    SNAPSHOT s1, s2
    li t0, 100
1:  addi t0, t0, -1
    bne t0, x0, 1b
    csrr t1, 0x7C0
    csrr t2, 0x7C1
    sub s1, t1, s1
    sub s2, t2, s2
    REPORT 1, s1
    REPORT 2, s2
    REPORT 3, t0
    PASS
    TAIL
