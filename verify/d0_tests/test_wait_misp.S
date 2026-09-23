// test_wait_misp.S -- imem_wait asserted across a mispredicting JAL.
// The JAL is cold (BTB miss -> predict not-taken -> mispredict). With
// imem_wait held through EX/resolve, the redirect must survive: rd must
// equal the return address and execution must continue at the target.
// Falling through to the instruction after the JAL is a FAIL.
#include "common.inc"
    .option norvc
    HDR
    jal t0, target
retaddr:
    # --- fall-through path: must NEVER retire ---
    li t5, (99 << 1) | 1
    sw t5, 0(s0)
9:  j 9b
target:
    la t1, retaddr
    bne t0, t1, fail        # rd != return address -> redirect broken
    REPORT 3, t0
    PASS
fail:
    li t5, (98 << 1) | 1
    sw t5, 0(s0)
9:  j 9b
    TAIL
