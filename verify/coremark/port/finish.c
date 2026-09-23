/*
 * finish.c -- final reporting for the bare-metal CoreMark run.
 *
 * Called from crt0 after main() returns. Reports through the testbench
 * tohost protocol (same as the IPC microbench):
 *     word = (id << 24) | (value & 0xFFFFFF)
 * ids:
 *   1 : timed-window cycles  [15:0]
 *   2 : timed-window cycles  [31:16]
 *   3 : timed-window instrs  [15:0]
 *   4 : timed-window instrs  [31:16]
 *   5 : iterations
 *   6 : crc_ok (1 = benchmark's own known-CRC checks passed, 0 = ERROR seen)
 *   7 : whole-program cycles [15:0]
 *   8 : whole-program cycles [31:16]
 *   9 : whole-program instrs [15:0]
 *  10 : whole-program instrs [31:16]
 *  12 : timed-window branches (0x7C0) [15:0]
 *  13 : timed-window branches (0x7C0) [31:16]
 *  14 : timed-window mispredicts (0x7C1) [15:0]
 *  15 : timed-window mispredicts (0x7C1) [31:16]
 * then word = 1 (PASS).
 */
#include "coremark.h"
#include "core_portme.h"

extern volatile ee_u32 tohost;
extern ee_u32 ee_log_has_error(void);
extern ee_u32 ee_log_has_crc_error(void);

static inline ee_u32 csr_mcycle(void)
{
    ee_u32 v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}
static inline ee_u32 csr_minstret(void)
{
    ee_u32 v;
    __asm__ volatile("csrr %0, minstret" : "=r"(v));
    return v;
}

static void report(ee_u32 id, ee_u32 value)
{
    tohost = (id << 24) | (value & 0xFFFFFFu);
}

void coremark_report_and_finish(void)
{
    ee_u32 cyc_end = csr_mcycle();
    ee_u32 ins_end = csr_minstret();

    /* timed window, captured by start_time()/stop_time() in the port */
    {
        extern CORETIMETYPE start_time_val, stop_time_val;
        extern ee_u32 start_instr_val, stop_instr_val;
        extern ee_u32 start_br_val, stop_br_val;
        extern ee_u32 start_misp_val, stop_misp_val;
        ee_u32 dc = stop_time_val - start_time_val;
        ee_u32 di = stop_instr_val - start_instr_val;
        ee_u32 db = stop_br_val - start_br_val;
        ee_u32 dm = stop_misp_val - start_misp_val;
        report(1, dc & 0xFFFFu);
        report(2, (dc >> 16) & 0xFFFFu);
        report(3, di & 0xFFFFu);
        report(4, (di >> 16) & 0xFFFFu);
        report(12, db & 0xFFFFu);
        report(13, (db >> 16) & 0xFFFFu);
        report(14, dm & 0xFFFFu);
        report(15, (dm >> 16) & 0xFFFFu);
    }
    report(5, (ee_u32)ITERATIONS);
    /* id 6: benchmark's known-CRC checks passed (computation correct).
     * The EEMBC "must execute >= 10 s" notice is a reporting-validity
     * rule, not a computation failure, and is tracked separately. */
    report(6, ee_log_has_crc_error() ? 0u : 1u);
    /* id 11: any ERROR line at all (includes the <10 s notice) */
    report(11, ee_log_has_error() ? 1u : 0u);

    /* whole program, from portable_init to here (untimed init included) */
    {
        extern ee_u32 prog_start_cyc, prog_start_ins;
        ee_u32 pdc = cyc_end - prog_start_cyc;
        ee_u32 pdi = ins_end - prog_start_ins;
        report(7, pdc & 0xFFFFu);
        report(8, (pdc >> 16) & 0xFFFFu);
        report(9, pdi & 0xFFFFu);
        report(10, (pdi >> 16) & 0xFFFFu);
    }

    tohost = 1u; /* PASS */
    for (;;)
        ;
}
