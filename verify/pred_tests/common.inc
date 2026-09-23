// common.inc -- shared macros for branch-predictor directed tests.
//
// Conventions:
//   s0        = tohost address (set once by each test)
//   s1/s2     = branch/mispredict counter snapshots (delta computed by test)
//   t5/t6     = clobbered by REPORT/PASS macros
//
// tohost protocol (same as tb_rv32imc.v):
//   sw (id<<24)|value -> [TB] REPORT id=.. value=..
//   sw 1              -> RESULT: PASS
// Report ids: 1 = delta branches (0x7C0), 2 = delta mispredicts (0x7C1),
//             3 = test checksum.

// Snapshot 0x7C0/0x7C1 into <br> and <misp>.
.macro SNAPSHOT br, misp
    csrr \br, 0x7C0
    csrr \misp, 0x7C1
.endm

// Report (\id << 24) | (\reg & 0xFFFFFF) to tohost.
.macro REPORT id, reg
    slli t6, \reg, 8
    srli t6, t6, 8
    li   t5, (\id << 24)
    or   t5, t5, t6
    sw   t5, 0(s0)
.endm

// Write PASS and park.
.macro PASS
    li t5, 1
    sw t5, 0(s0)
9:  j 9b
.endm

// Standard _start + tohost section. Body goes between HDR and TAIL.
.macro HDR
    .section .text.init, "ax"
    .globl _start
    .type _start, @function
_start:
    la sp, _stack_top
    la s0, tohost
.endm

.macro TAIL
    .pushsection .tohost, "aw", @progbits
    .align 2
    .globl tohost
    .type tohost, @object
tohost:
    .word 0
    .size tohost, .-tohost
    .popsection
.endm
