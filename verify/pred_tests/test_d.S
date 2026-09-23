// test_d.s -- nested loops: outer 10, inner 20.
// Inner bne (200x): cold mispredict on first outer iter + one exit
//   mispredict per outer iter = 1 + 10 = 11.
// Outer bne (10x: 9T+1NT): cold + final exit = 2.
// Expected: branches=210, mispredicts=13, checksum (t0|t1)=0.
#include "common.inc"
    .option norvc
    HDR
    SNAPSHOT s1, s2
    li t0, 10
1:  li t1, 20
2:  addi t1, t1, -1
    bne t1, x0, 2b
    addi t0, t0, -1
    bne t0, x0, 1b
    csrr t3, 0x7C0
    csrr t4, 0x7C1
    sub s1, t3, s1
    sub s2, t4, s2
    or t3, t0, t1
    REPORT 1, s1
    REPORT 2, s2
    REPORT 3, t3
    PASS
    TAIL
