// test_wait_soc.S -- SoC-like address-change-triggered 2-wait corner tests.
//
// Run with: +imem_wait_pat=3 [+dmem_wait_pat=3]
// Pattern 3 mimics the SoC SDRAM model: a NEW address asserts wait
// COMBINATORIALLY in the same cycle, then 2 wait cycles. This is the
// stimulus that exposed the wait x mispredict corner (registered LFSR /
// window patterns never assert wait in the exact resolve cycle).
//
// Part A (I-port): c.jal + plain jal under I-port waits.
//   - 1st c.jal: cold (mispredict) -- must retire, ra = return address.
//   - 2nd c.jal: predicted taken (BTB trained) -- must retire, ra correct.
//   - plain jal (32-bit): same checks.
//   - If any link is wrong (ra=0 or ra=PC+4 for compressed), FAIL.
// Part B (D-port): MMIO write/read exactly-once under D-port waits.
//   - Write a pattern to a scratch word; read it back; must match.
//   - A write counter in the testbench (via tohost REPORT) proves
//     exactly-once commit (no dropped, no duplicated writes).
#include "common.inc"
    HDR
    # ---- Part A: c.jal x2 ----
    li t0, 2
1:
    c.jal func
ret_lab:
    addi t0, t0, -1
    bnez t0, 1b
    # verify both calls saved the right ra
    la t1, saved_ra
    lw t2, 0(t1)
    lw t3, 4(t1)
    la t1, ret_lab
    bne t2, t1, fail
    bne t3, t1, fail
    REPORT 3, t3            # id=3: c.jal ra checksum (expect ret_lab)

    # ---- Part A2: plain jal x2 (32-bit) ----
    li t0, 2
2:
    jal ra, func32
ret_lab32:
    addi t0, t0, -1
    bnez t0, 2b
    la t1, saved_ra32
    lw t2, 0(t1)
    lw t3, 4(t1)
    la t1, ret_lab32
    bne t2, t1, fail
    bne t3, t1, fail
    REPORT 3, t3            # id=3: jal ra checksum (expect ret_lab32)

    # ---- Part B: D-port MMIO exactly-once ----
    # Use a scratch word in .bss as "MMIO". Write 0xA5A5A5A5 twice with a
    # read in between; the testbench counts commits via REPORT id=4.
    la t1, mmio_word
    li t2, 0xA5A5A5A5
    sw t2, 0(t1)
    lw t3, 0(t1)
    bne t3, t2, fail        # read-back mismatch -> lost/duplicated write
    li t2, 0x5A5A5A5A
    sw t2, 0(t1)
    lw t3, 0(t1)
    bne t3, t2, fail
    REPORT 4, t3            # id=4: final MMIO value (expect 0x5A5A5A5A)

    PASS
fail:
    li t5, (98 << 1) | 1
    sw t5, 0(s0)
9:  j 9b

func:
    la t1, saved_ra
    lw t4, 0(t1)
    sw t4, 4(t1)
    sw ra, 0(t1)
    ret
func32:
    la t1, saved_ra32
    lw t4, 0(t1)
    sw t4, 4(t1)
    sw ra, 0(t1)
    ret

    .pushsection .bss, "aw", @nobits
    .align 2
saved_ra:
    .word 0, 0
saved_ra32:
    .word 0, 0
mmio_word:
    .word 0
    .popsection
    TAIL
