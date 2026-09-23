# ---------------------------------------------------------------------------
# constraint.sdc - timing constraints for rv32imc_top
#
# The core talks to external instruction/data SRAMs over single-cycle
# combinational-read buses. IO timing is budgeted as a fraction of the
# clock period so the constraint tracks CLOCK_PERIOD automatically.
# ---------------------------------------------------------------------------

current_design rv32imc_top

# Clock --------------------------------------------------------------------
set clk_period 10.0
set clk_port   [get_ports $::env(CLOCK_PORT)]
create_clock -name core_clk -period $clk_period $clk_port
set_clock_uncertainty -setup 0.150 [get_clocks core_clk]
set_clock_uncertainty -hold  0.050 [get_clocks core_clk]
set_clock_transition 0.150 [get_clocks core_clk]

# IO budget: 25% of period in, 25% out --------------------------------------
# The clock port and async reset are excluded from data-IO constraints.
set io_pct 0.25
set in_delay  [expr {$clk_period * $io_pct}]
set out_delay [expr {$clk_period * $io_pct}]

# The data inputs are the two combinational SRAM read buses; clock and async
# reset are deliberately excluded (listed explicitly because this OpenSTA
# build supports neither remove_from_collection nor foreach_in_collection).
set data_inputs [get_ports {imem_rdata[*] dmem_rdata[*]}]

set_input_delay  -clock core_clk -max $in_delay  $data_inputs
set_input_delay  -clock core_clk -min 0.0        $data_inputs
set_output_delay -clock core_clk -max $out_delay [all_outputs]
set_output_delay -clock core_clk -min 0.0       [all_outputs]

# Driving cell / load: modest, matches a neighboring SRAM macro -------------
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_4 $data_inputs
set_load 0.050 [all_outputs]

# Async reset: not part of the synchronous timing budget --------------------
set_false_path -from [get_ports rst_n]
set_ideal_network [get_ports rst_n]
