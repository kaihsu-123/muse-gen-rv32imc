// test_e.s -- JALR with alternating targets (BTB must track).
// Loop 10x; the indirect jump alternates between L_A and L_B.
//   jalr: iter1 cold miss -> mispredict; iters 2..10: BTB hit but stale
//         target -> mispredict every time = 10.
//   jal in L_A (5x, always to 3f): 1 cold mispredict, then perfect.
//   bne loop (9T+1NT): cold + exit = 2.
// Expected: branches=25, mispredicts=13, checksum t0=0.
#include "common.inc"
    .option norvc
    HDR
    SNAPSHOT s1, s2
    li t0, 10
    la t5, L_A
    la t6, L_B
    mv s3, t5
1:  jalr x0, 0(s3)
L_A:
    mv s3, t6
    jal x0, 3f
L_B:
    mv s3, t5
3:  addi t0, t0, -1
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
