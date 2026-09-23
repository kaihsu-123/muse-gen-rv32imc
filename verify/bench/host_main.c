/* host_main.c -- host cross-check for microbench checksums.
 * Compile natively:  gcc -O2 microbench.c host_main.c -o microbench_host
 * Prints: "<checksum> <b0> <b1> <b2> <b3> <b4>" in hex. run_tests.sh
 * compares the checksum with the value reported by the RTL simulation.
 */
#include <stdint.h>
#include <stdio.h>

extern uint32_t run_all(uint32_t out[5]);

int main(void) {
    uint32_t out[5];
    uint32_t chk = run_all(out);
    printf("%08x %08x %08x %08x %08x %08x\n",
           chk, out[0], out[1], out[2], out[3], out[4]);
    return 0;
}
