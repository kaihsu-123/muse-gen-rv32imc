// test_wait_mix.S -- mixed workload checksum.
// Must produce a bit-identical checksum with and without imem_wait /
// dmem_wait stimulus: no instruction lost, no request dropped/re-issued,
// no duplicate retirement under stalls.
#include "common.inc"
    .option norvc
    HDR
    la s1, scratch
    li t0, 0
    li t1, 200
    li t2, 0x9e3779b9
1:
    add t0, t0, t2
    xor t2, t2, t0
    slli t3, t2, 3
    add t0, t0, t3
    mul t3, t0, t2
    add t0, t0, t3
    sw t0, 0(s1)
    lw t4, 0(s1)
    add t0, t0, t4
    andi t5, t0, 255
    beq t5, x0, 2f
    addi t0, t0, 1
2:
    addi t1, t1, -1
    bne t1, x0, 1b
    REPORT 3, t0
    PASS
    .section .bss
    .align 2
scratch:
    .word 0
    TAIL
