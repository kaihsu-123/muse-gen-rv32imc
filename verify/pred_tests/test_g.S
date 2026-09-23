// test_g.s -- BTB target bit 1: JALR to an odd-halfword (16-bit-parcel)
// target, repeated. The BTB stores the target as PC[31:1]; if bit 1 were
// dropped (storing only PC[31:2]), the 2nd/3rd predictions would carry a
// corrupted target and mispredict.
//
// Sequence (3 iterations):
//   j L_jalr            cold -> mispredict #1. branches+1.
//   jalr x0, 0(t0)->L_odd_target:
//     iter1: BTB miss -> predict NT -> mispredict #2. BTB = {L_odd_target}.
//     iter2,3: BTB hit, BHT>=2 -> predict T to stored target; must equal
//            L_odd_target exactly (bit 1 preserved) -> correct.
//   bne (3x: 2T+1NT): cold + exit = 2 mispredicts. branches+3.
//   j L_done            cold -> mispredict #5. branches+1.
// Expected: branches=8, mispredicts=5, checksum t1=0.
// (With the bit-1-dropping bug: mispredicts would be 7.)
#include "common.inc"
    .option rvc
    HDR
    csrr s1, 0x7C0
    csrr s2, 0x7C1
    la t0, L_odd_target
    li t1, 3
    j L_jalr
    .align 2
    c.nop                 // filler (never executed): L_odd_target lands
                          // on an odd halfword (bit 1 = 1)
L_odd_target:
    addi t1, t1, -1
    bne t1, x0, L_jalr
    j L_done
L_jalr:
    jalr x0, 0(t0)
L_done:
    csrr t3, 0x7C0
    csrr t4, 0x7C1
    sub s1, t3, s1
    sub s2, t4, s2
    REPORT 1, s1
    REPORT 2, s2
    REPORT 3, t1
    PASS
    TAIL
