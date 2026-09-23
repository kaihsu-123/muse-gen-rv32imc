/* microbench.c -- small IPC microbenchmarks for the RV32IMC CPU.
 *
 * Each bench_*() runs a tight loop stressing one part of the pipeline:
 *   1 : ALU + predictable branches   (base CPI)
 *   2 : unpredictable branches       (branch mispredict penalty)
 *   3 : load-use dependency chains   (load-use stall penalty)
 *   4 : multiply chains              (M-extension latency/throughput)
 *   5 : mixed workload               (dhrystone-like mix)
 *   6 : overall IPC over the whole run (reported by bench_main)
 *   7 : checksum of all bench results (correctness cross-check vs host)
 *
 * The functions are shared between the RISC-V target (bench_main.c) and
 * the host cross-check (host_main.c). Loop trip counts are compile-time
 * constants; results are accumulated into the returned checksum so the
 * optimizer cannot delete the loops. `sink` is volatile as a backstop.
 */
#include <stdint.h>

volatile uint32_t sink;

__attribute__((noinline)) uint32_t bench_alu(void) {
    uint32_t a = 0x12345678u, b = 0x9abcdef0u, s = 0;
    for (int i = 0; i < 20000; i++) {
        a += (b ^ (a << 3)) + (uint32_t)i;
        b += (a ^ (b >> 2)) - (uint32_t)i;
        /* highly predictable branch: taken ~7/8 of the time */
        if ((i & 7) != 7) s += a; else s -= b;
        s += (a & b) | (a ^ 0x5a5a5a5au);
    }
    sink = s;
    return s;
}

__attribute__((noinline)) uint32_t bench_branch(void) {
    /* xorshift32 PRNG -> ~50% unpredictable branches, no multiplies */
    uint32_t x = 0x2545F491u, s = 0;
    for (int i = 0; i < 20000; i++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        if (x & 0x80000000u) s += x;
        else                 s -= x;
    }
    sink = s;
    return s;
}

static uint32_t lmem[256];

__attribute__((noinline)) uint32_t bench_loaduse(void) {
    for (int i = 0; i < 256; i++)
        lmem[i] = (uint32_t)((i * 37 + 11) & 255);
    uint32_t idx = 0, s = 0;
    for (int i = 0; i < 20000; i++) {
        idx = lmem[idx & 255];   /* dependent load chain */
        s += idx + (uint32_t)i;
    }
    sink = s;
    return s;
}

__attribute__((noinline)) uint32_t bench_mul(void) {
    uint32_t a = 12345u, b = 67890u, s = 0;
    for (int i = 0; i < 20000; i++) {
        a = a * 1103515245u + 12345u;
        s += (a >> 8) * b;       /* dependent multiply chain */
        b = b * 22695477u + 1u;
    }
    sink = s;
    return s;
}

__attribute__((noinline)) static uint32_t fib_small(uint32_t n) {
    uint32_t x = 0, y = 1;
    for (uint32_t k = 0; k < n; k++) {
        uint32_t t = x + y;
        x = y;
        y = t;
    }
    return x;
}

static uint32_t mbuf[64];

__attribute__((noinline)) uint32_t bench_mix(void) {
    uint32_t s = 0;
    for (int i = 0; i < 30000; i++) {
        int v = i * 7 + 3;
        v = (v > 500) ? (v - 500) : (v + 7);       /* branch */
        mbuf[i & 63] = (uint32_t)v;                /* store */
        s += mbuf[(uint32_t)(v * 13) & 63];        /* load */
        s += fib_small((uint32_t)v & 15);          /* call */
        s ^= (uint32_t)(v * 31);                   /* alu */
    }
    sink = s;
    return s;
}

/* Run every bench once and fold the results into a single checksum. */
uint32_t run_all(uint32_t out[5]) {
    out[0] = bench_alu();
    out[1] = bench_branch();
    out[2] = bench_loaduse();
    out[3] = bench_mul();
    out[4] = bench_mix();
    uint32_t c = 0x9e3779b9u;
    for (int i = 0; i < 5; i++)
        c ^= out[i] + 0x9e3779b9u + (c << 6) + (c >> 2);
    return c;
}
