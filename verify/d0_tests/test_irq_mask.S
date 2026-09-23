// test_irq_mask.S -- an interrupt must NOT be taken when it is masked:
// phase A: mie bit clear (MIE = 1), MTI pending
// phase B: MIE = 0 (mie bit set), MTI pending
// Reaching PASS (via both delay loops) proves the trap was never taken;
// any trap lands in the fail handler.
#include "common.inc"
    .option norvc
    HDR
    la t0, fail_handler
    csrw mtvec, t0
    lui s1, 0xFFFF0         # s1 = 0xFFFF0000 (magic mip MMIO)
    # phase A: MIE=1, mie=0 (MTI masked) -> no take
    csrw mie, zero
    li t0, 0x8
    csrs mstatus, t0
    li t0, 0x80
    sw t0, 0(s1)            # pend MTI
    li t0, 400
1:  addi t0, t0, -1
    bnez t0, 1b
    # phase B: MIE=0, mie=MTI -> no take
    li t0, 0x80
    csrw mie, t0
    csrc mstatus, 0x8
    li t0, 400
1:  addi t0, t0, -1
    bnez t0, 1b
    # still here: the pending interrupt was never taken
    sw zero, 0(s1)          # clear pending (cleanliness)
    REPORT 3, t0            # expect 0
    bnez t0, fail
    PASS
fail_handler:
fail:
    li t5, (94 << 1) | 1
    sw t5, 0(s0)
9:  j 9b
    TAIL
