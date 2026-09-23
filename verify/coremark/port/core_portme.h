/*
 * core_portme.h -- bare-metal port of EEMBC CoreMark to the RV32IMC CPU.
 *
 * Target: 5-stage RV32IMC core, no OS, Icarus Verilog functional sim.
 * Timing: mcycle / minstret CSRs read with inline asm (part of the port's
 * timing implementation, not of the timed benchmark code).
 *
 * The timed benchmark sources (core_list_join.c, core_matrix.c,
 * core_state.c, core_util.c, coremark.c/core_main.c, coremark.h) are
 * UNMODIFIED from the EEMBC CoreMark repository.
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>
#include <stdint.h>

/************************/
/* Data types and settings */
/************************/
#ifndef HAS_FLOAT
#define HAS_FLOAT 0           /* integer-only target, no FPU */
#endif
#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif
#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif
#ifndef HAS_STDIO
#define HAS_STDIO 0
#endif
#ifndef HAS_PRINTF
#define HAS_PRINTF 0          /* we provide our own ee_printf */
#endif

#ifndef COMPILER_VERSION
#ifdef __GNUC__
#define COMPILER_VERSION "GCC" __VERSION__
#else
#define COMPILER_VERSION "unknown"
#endif
#endif
#include "flags_str.h"
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

typedef int8_t   ee_s8;
typedef uint8_t  ee_u8;
typedef int16_t  ee_s16;
typedef uint16_t ee_u16;
typedef int32_t  ee_s32;
typedef uint32_t ee_u32;
typedef ee_u32   ee_ptr_int;
typedef size_t   ee_size_t;
#define NULL ((void *)0)

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

/* Timing type: CPU cycle counts from the mcycle CSR. */
#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

/* The testbench runs a 100 MHz functional clock (10 ns period). */
#define CLOCKS_PER_SEC 100000000UL

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STATIC
#endif
#ifndef MULTITHREAD
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0
#endif
#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

/* target specific init/fini */
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

/* Elapsed retired instructions inside the timed window, for IPC. */
ee_u32 port_timed_instr(void);
ee_u32 port_timed_br(void);
ee_u32 port_timed_misp(void);

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */
