/* bench_main.c -- RISC-V target entry for the IPC microbenchmark.
 *
 * Measures mcycle/minstret around each bench_*() and around the whole run,
 * then reports via tohost using the testbench protocol:
 *     word = (id << 24) | (ipc_x1000 & 0xFFFFFF)   for ids 1..6
 *     word = (7  << 24) | (checksum  & 0xFFFFFF)    correctness cross-check
 *     word = 1                                      PASS (end of run)
 */
#include <stdint.h>

extern volatile uint32_t tohost;
extern uint32_t run_all(uint32_t out[5]);
extern uint32_t bench_alu(void);
extern uint32_t bench_branch(void);
extern uint32_t bench_loaduse(void);
extern uint32_t bench_mul(void);
extern uint32_t bench_mix(void);

static inline uint32_t csr_mcycle(void) {
    uint32_t v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

static inline uint32_t csr_minstret(void) {
    uint32_t v;
    __asm__ volatile("csrr %0, minstret" : "=r"(v));
    return v;
}

static inline void tohost_write(uint32_t v) {
    tohost = v;
}

/* fixed-point IPC report: id in [1..6] */
static void report_ipc(int id, uint32_t c0, uint32_t c1,
                       uint32_t i0, uint32_t i1) {
    uint32_t dc = c1 - c0;
    uint32_t di = i1 - i0;
    uint32_t ipc_x1000 = dc ? (uint32_t)(((uint64_t)di * 1000u) / dc) : 0;
    tohost_write(((uint32_t)id << 24) | (ipc_x1000 & 0xFFFFFFu));
}

int main(void) {
    uint32_t c1, i1;
    uint32_t out[5];
    uint32_t cA, iA;

    /* overall window starts before the first bench */
    cA = csr_mcycle(); iA = csr_minstret();

    c1 = csr_mcycle(); i1 = csr_minstret(); out[0] = bench_alu();
    report_ipc(1, c1, csr_mcycle(), i1, csr_minstret());

    c1 = csr_mcycle(); i1 = csr_minstret(); out[1] = bench_branch();
    report_ipc(2, c1, csr_mcycle(), i1, csr_minstret());

    c1 = csr_mcycle(); i1 = csr_minstret(); out[2] = bench_loaduse();
    report_ipc(3, c1, csr_mcycle(), i1, csr_minstret());

    c1 = csr_mcycle(); i1 = csr_minstret(); out[3] = bench_mul();
    report_ipc(4, c1, csr_mcycle(), i1, csr_minstret());

    c1 = csr_mcycle(); i1 = csr_minstret(); out[4] = bench_mix();
    report_ipc(5, c1, csr_mcycle(), i1, csr_minstret());

    /* overall IPC across the five benches */
    report_ipc(6, cA, csr_mcycle(), iA, csr_minstret());

    /* checksum folded from the first-run results (deterministic, matches
     * host which runs each bench once on fresh static storage) */
    {
        uint32_t c = 0x9e3779b9u;
        for (int i = 0; i < 5; i++)
            c ^= out[i] + 0x9e3779b9u + (c << 6) + (c >> 2);
        tohost_write((7u << 24) | (c & 0xFFFFFFu));
    }

    tohost_write(1u);   /* PASS */
    return 0;
}
