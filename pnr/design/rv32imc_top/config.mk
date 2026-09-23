# ---------------------------------------------------------------------------
# OpenROAD-flow-scripts design configuration for the RV32IMC CPU.
#
# Usage (from this design directory, after `source ../../env.sh`):
#   make -C $RV32IMC_TOP/tools/orfs/flow DESIGN_CONFIG=$PWD/config.mk synth
#   make -C $RV32IMC_TOP/tools/orfs/flow DESIGN_CONFIG=$PWD/config.mk
#
# CLOCK_PERIOD: timing *target* for the run. Sign-off goal is 100 MHz
# (10 ns). Start at 120 MHz (8.333 ns) to probe timing margin; relax to
# 10.0 once the critical paths are understood, or keep pushing below 8.333
# if it closes easily.
#   make ... CLOCK_PERIOD=10.0      # sign-off run at 100 MHz
# ---------------------------------------------------------------------------

export PLATFORM                 = sky130hd

export DESIGN_NAME              = rv32imc_top
export DESIGN_HOME              := $(dir $(lastword $(MAKEFILE_LIST)))
export VERILOG_FILES            = $(sort $(wildcard $(RV32IMC_TOP)/rtl/*.v))
# exclude testbenches if the sibling adds any under rtl/
export VERILOG_FILES            := $(filter-out %_tb.v %/tb_%.v,$(VERILOG_FILES))

export SDC_FILE                 = $(DESIGN_HOME)/constraint.sdc
export CLOCK_PERIOD             ?= 8.333
export CLOCK_PORT               = clk

# --- synthesis -------------------------------------------------------------
export SYNTH_HIERARCHICAL       = 0
export ABC_AREA                 = 1

# --- floorplan -------------------------------------------------------------
# Small core (~30k gates); let the flow size the die from utilization.
export CORE_UTILIZATION         = 45
export CORE_ASPECT_RATIO        = 1
export CORE_MARGIN              = 2

# --- placement -------------------------------------------------------------
export PLACE_DENSITY            = 0.65
export TNS_END_PERCENT          = 100

# --- CTS -------------------------------------------------------------------
export CTS_BUF_DISTANCE         = 50

# --- routing ---------------------------------------------------------------
export ROUTE_EXTRA_SPACE        = 1

# --- power -----------------------------------------------------------------
# (default PDN_TCL from the sky130hd platform is used)

# --- STA / signoff ---------------------------------------------------------
export SETUP_SLACK_MARGIN       = -0.050

# --- detail route iteration cap (shorten wall time to fit restart windows) --
export DETAILED_ROUTE_END_ITERATION = 3

# --- skip post-DRT antenna repair loop (saves wall time) ----------------------
export SKIP_ANTENNA_REPAIR_POST_DRT = 1

# --- skip RCX extraction (set_extraction_rules_file not in this OpenROAD) -----
export RCX_RULES =
