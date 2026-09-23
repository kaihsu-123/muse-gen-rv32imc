// test_wait_loaduse.S -- dmem_wait (LFSR stimulus) during a load feeding a
// dependent ALU op. The load-use interlock + dmem_wait must compose: the
// forwarded value must be exact, exactly once.
#include "common.inc"
    .option norvc
    HDR
    la s1, scratch
    li t0, 0x12345678
    sw t0, 0(s1)
    lw t1, 0(s1)            # load whose MEM stage hits dmem_wait
    addi t2, t1, 1          # load-use dependent
    xor t3, t1, t2
    REPORT 3, t2            # expect 0x12345679
    REPORT 4, t3            # expect 0x12345678 ^ 0x12345679 == 1
    li t4, 0x12345679
    bne t2, t4, fail
    li t4, 1
    bne t3, t4, fail
    PASS
fail:
    li t5, (97 << 1) | 1
    sw t5, 0(s0)
9:  j 9b
    .section .bss
    .align 2
scratch:
    .word 0
    TAIL
