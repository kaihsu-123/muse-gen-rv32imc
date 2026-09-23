// test_irq_prio.S -- MEI(11) > MSI(3) > MTI(7) priority.
// All three lines are pended at once; the handler must observe the takes
// in order MEI, MSI, MTI, clearing one line per take. After the third take
// it resumes the main code, which checks exactly 3 takes happened.
#include "common.inc"
    .option norvc
    HDR
    la t0, handler
    csrw mtvec, t0
    li t0, 0x888
    csrw mie, t0            # enable MEI + MSI + MTI
    li t0, 0x8
    csrs mstatus, t0        # MIE = 1
    lui s1, 0xFFFF0         # s1 = 0xFFFF0000 (magic mip MMIO)
    li s2, 0                # take count
    li s3, 0x888            # remaining mask
    li t3, 0x888
    sw t3, 0(s1)            # pend all three
wait_loop:
    j wait_loop
done:
    REPORT 1, s2            # expect 3
    li t3, 3
    bne s2, t3, fail
    PASS
handler:
    addi s2, s2, 1
    csrr t0, mcause
    li t1, 1
    bne s2, t1, chk2
    li t1, 0x8000000b       # 1st take must be MEI (highest)
    j chkc
chk2:
    li t1, 2
    bne s2, t1, chk3
    li t1, 0x80000003       # 2nd take must be MSI
    j chkc
chk3:
    li t1, 0x80000007       # 3rd take must be MTI
chkc:
    bne t0, t1, fail        # wrong priority order
    # clear the serviced line from the remaining mask
    li t1, 1
    bne s2, t1, clr2
    li t1, 0x800
    j clrc
clr2:
    li t1, 2
    bne s2, t1, clr3
    li t1, 0x8
    j clrc
clr3:
    li t1, 0x80
clrc:
    xor s3, s3, t1          # bit was set -> now cleared
    sw s3, 0(s1)            # rewrite mip with the line cleared
    li t1, 3
    bne s2, t1, do_mret
    la t0, done
    csrw mepc, t0           # after the 3rd take, resume at done
do_mret:
    mret
fail:
    li t5, (95 << 1) | 1
    sw t5, 0(s0)
9:  j 9b
    TAIL
