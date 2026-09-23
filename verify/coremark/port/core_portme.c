/*
 * core_portme.c -- bare-metal CoreMark port for the RV32IMC CPU.
 *
 * Timing uses the RISC-V mcycle / minstret CSRs (inline asm). The timed
 * window is bracketed by start_time()/stop_time(); the same two calls also
 * capture minstret so IPC = dinstr/dcycles can be reported honestly.
 * Nothing here alters the timed benchmark sources.
 */
#include "coremark.h"
#include "core_portme.h"

/* ---- CSR access (port timing infrastructure) ---- */
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

/* Branch-predictor performance counters (custom read-only CSRs in csr.v):
 * 0x7C0 = control-flow instructions resolved, 0x7C1 = mispredictions.
 * Read alongside mcycle/minstret so the timed window covers all three. */
static inline ee_u32 csr_branch(void)
{
    ee_u32 v;
    __asm__ volatile("csrr %0, 0x7C0" : "=r"(v));
    return v;
}
static inline ee_u32 csr_mispredict(void)
{
    ee_u32 v;
    __asm__ volatile("csrr %0, 0x7C1" : "=r"(v));
    return v;
}

/* ---- seeds: PERFORMANCE_RUN defaults (EEMBC run rules) ---- */
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define GETMYTIME(_t)        (*(_t) = csr_mcycle())
#define MYTIMEDIFF(fin, ini) ((fin) - (ini))
#define TIMER_RES_DIVIDER    1
#define EE_TICKS_PER_SEC     (CLOCKS_PER_SEC / TIMER_RES_DIVIDER)

CORETIMETYPE start_time_val, stop_time_val;
ee_u32       start_instr_val, stop_instr_val;
ee_u32       start_br_val, stop_br_val;
ee_u32       start_misp_val, stop_misp_val;
ee_u32       prog_start_cyc, prog_start_ins;

void start_time(void)
{
    GETMYTIME(&start_time_val);
    start_instr_val = csr_minstret();
    start_br_val = csr_branch();
    start_misp_val = csr_mispredict();
}

void stop_time(void)
{
    GETMYTIME(&stop_time_val);
    stop_instr_val = csr_minstret();
    stop_br_val = csr_branch();
    stop_misp_val = csr_mispredict();
}

CORE_TICKS get_time(void)
{
    CORE_TICKS elapsed = (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

/* Elapsed retired instructions inside the timed window (for IPC). */
ee_u32 port_timed_instr(void)
{
    return stop_instr_val - start_instr_val;
}

/* Elapsed branch-predictor counters inside the timed window. */
ee_u32 port_timed_br(void)
{
    return stop_br_val - start_br_val;
}
ee_u32 port_timed_misp(void)
{
    return stop_misp_val - start_misp_val;
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    p->portable_id = 1;
    prog_start_cyc = csr_mcycle();
    prog_start_ins = csr_minstret();
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

/* portable_malloc/free are unused with MEM_STATIC, but coremark.h declares
 * them; provide trivial definitions so nothing dangles. */
void *portable_malloc(ee_size_t size)
{
    (void)size;
    return NULL;
}
void portable_free(void *p)
{
    (void)p;
}
