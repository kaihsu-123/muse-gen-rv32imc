/* crt0.S -- minimal startup for the CoreMark bare-metal run.
 * Sets up the stack, calls main(), then calls coremark_report_and_finish()
 * which reports cycles/instructions via tohost and signals PASS.
 * Provides the `tohost` symbol in its own section so the testbench can
 * find it via nm (same convention as verify/bench/crt0.S).
 */
  .section .text.init, "ax"
  .globl _start
  .type  _start, @function
_start:
  la sp, _stack_top
  call main
  call coremark_report_and_finish
  /* should never return; hang here */
1:j 1b
  .size _start, .-_start

  .pushsection .tohost, "aw", @progbits
  .align 2
  .globl tohost
  .type  tohost, @object
tohost:
  .word 0
  .size tohost, .-tohost
  .popsection
