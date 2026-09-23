// test_f.s -- BTB halfword aliasing: false-positive prediction on a
// non-branch instruction must be caught by the EX mispredict flush.
//
// Layout (RVC): a 16-bit taken branch at the EVEN halfword of a word,
// a 16-bit non-branch (c.addi) at the ODD halfword of the SAME word.
// Both share BTB index PC[7:2] and tag PC[31:8].
//
// Sequence:
//   j L_word            cold -> mispredict #1. branches+1.
//   c.beqz a0, L_taken  BTB miss -> predict NT, actual T -> mispredict #2.
//                       BTB[L_word] = {L_taken}, BHT 01->10. branches+1.
//   jalr x0, 0(t0)->L_odd  cold -> mispredict #3. branches+1.
//   c.addi a1, a1, 1 @L_odd: BTB HIT (alias) -> BHT=10 -> predict TAKEN to
//                       L_taken. EX: non-CF + pred_taken -> mispredict #4
//                       (false positive), flush to fall-through L_after.
//                       The c.addi itself retires: a1 = 1.
// Expected: branches=3, mispredicts=4, checksum a1=1.
// NOTE: c.beqz/c.addi need x8-x15 registers (a0=x10, a1=x11).
#include "common.inc"
    .option rvc
    HDR
    csrr s1, 0x7C0
    csrr s2, 0x7C1
    li a0, 0
    li a1, 0
    j L_word
    .align 2
L_word:
    c.beqz a0, L_taken
L_odd:
    addi a1, a1, 1        // assembles to 16-bit c.addi (explicit c.addi
                          // mnemonic is rejected by this assembler)
L_after:
    csrr t1, 0x7C0
    csrr t2, 0x7C1
    sub s1, t1, s1
    sub s2, t2, s2
    REPORT 1, s1
    REPORT 2, s2
    REPORT 3, a1
    PASS
L_taken:
    la t0, L_odd
    jalr x0, 0(t0)
    TAIL
