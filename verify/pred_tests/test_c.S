// test_c.s -- alternating taken/not-taken pattern (200 iterations).
// A 2-bit saturating counter cannot learn a period-2 pattern: every
// iteration mispredicts in steady state (hand-traced):
//   T: miss->NT->mis (01->10); N: hit,T->mis (10->01); T: hit,NT->mis ...
//   => 200 mispredicts on the alternating branch.
// Loop bne (199T+1NT): cold + exit = 2 mispredicts.
// Expected: branches=400, mispredicts=202, checksum t4=100.
#include "common.inc"
    .option norvc
    HDR
    SNAPSHOT s1, s2
    li t0, 200
    li t4, 0
1:  andi t2, t0, 1
    beq t2, x0, 2f     // taken when t0 even: T,N,T,N... (starts T)
    addi t4, t4, 1     // t0 odd path
2:  addi t0, t0, -1
    bne t0, x0, 1b
    csrr t1, 0x7C0
    csrr t2, 0x7C1
    sub s1, t1, s1
    sub s2, t2, s2
    REPORT 1, s1
    REPORT 2, s2
    REPORT 3, t4
    PASS
    TAIL
