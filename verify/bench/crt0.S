/* crt0.S -- minimal startup for the IPC microbenchmark.
 * Sets up the stack, calls main(), then parks. Provides the `tohost`
 * symbol in its own section so the testbench can find it via nm.
 */
  .section .text.init, "ax"
  .globl _start
  .type  _start, @function
_start:
  la sp, _stack_top
  call main
  /* main() reports via tohost itself; if it ever returns, hang here */
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
