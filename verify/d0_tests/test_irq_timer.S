// test_irq_timer.S -- machine timer interrupt (mip[7]).
// The test pends MTI mid-loop via the magic MMIO at 0xFFFF0000 (a store
// there overwrites the DUT's mip_in). Checks:
//   - mcause == 0x80000007, mepc inside [main_loop, main_end)
//   - mret resumes the main loop cleanly
//   - the main counter reaches exactly 30 (no lost/duplicated retire)
//   - exactly one interrupt was taken
#include "common.inc"
    .option norvc
    HDR
    la t0, handler
    csrw mtvec, t0
    li t0, 0x80
    csrw mie, t0            # enable MTI only
    li t0, 0x8
    csrs mstatus, t0        # MIE = 1
    lui s1, 0xFFFF0         # s1 = 0xFFFF0000 (magic mip MMIO)
    li s2, 0                # interrupt count
    li t2, 0                # main counter
main_loop:
    addi t2, t2, 1
    li t3, 10
    bne t2, t3, no_trig
    li t3, 0x80
    sw t3, 0(s1)            # pend MTI
no_trig:
    li t3, 30
    blt t2, t3, main_loop
main_end:
    REPORT 1, t2            # expect 30
    REPORT 2, s2            # expect 1
    li t3, 30
    bne t2, t3, fail
    li t3, 1
    bne s2, t3, fail
    PASS
handler:
    csrr t0, mcause
    li t1, 0x80000007
    bne t0, t1, fail        # wrong cause
    csrr t0, mepc
    la t1, main_loop
    blt t0, t1, fail        # mepc below main range
    la t1, main_end
    bge t0, t1, fail        # mepc at/above end of main range
    sw zero, 0(s1)          # clear mip[7] (no immediate retake)
    addi s2, s2, 1
    mret
fail:
    li t5, (96 << 1) | 1
    sw t5, 0(s0)
9:  j 9b
    TAIL
