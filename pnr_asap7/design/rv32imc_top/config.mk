# ---------------------------------------------------------------------------
# OpenROAD-flow-scripts design configuration for the RV32IMC CPU on ASAP7.
#
# Goal: apples-to-apples comparison against Astra RV5's reported
# 1.50 GHz (666.667 ps) closure on ASAP7 BC/FF, 0.77 V, 0 C, 20 ps uncertainty.
#
# PDK: the public ASAP7 PDK as vendored inside ORFS
#   tools/orfs/flow/platforms/asap7/{lef,lib,gds}
#   (no separate download; versions recorded in pnr_asap7/RESULTS.md).
# Corner: BC = FF libs (asap7sc7p5t_*_FF_nldm), 0.77 V, 0 C (overridden below).
# Primary VT: RVT (ORFS default).
# ---------------------------------------------------------------------------

export PLATFORM                 = asap7
export CORNER                   = BC
export LIB_MODEL                = NLDM
export BC_TEMPERATURE           = 0C
export BC_VOLTAGE               = 0.77

export DESIGN_NAME              = rv32imc_top
export DESIGN_HOME              := $(dir $(lastword $(MAKEFILE_LIST)))
export VERILOG_FILES            = $(sort $(wildcard $(RV32IMC_TOP)/rtl/*.v))
# exclude testbenches if the sibling adds any under rtl/
export VERILOG_FILES            := $(filter-out %_tb.v %/tb_%.v,$(VERILOG_FILES))

export SDC_FILE                 = $(DESIGN_HOME)/constraint.sdc
# NOTE: ASAP7 liberty time_unit is 1ps, so CLOCK_PERIOD is in PICOSECONDS.
# 667 ps = 1.50 GHz (Astra RV5 comparison basis).
export CLOCK_PERIOD             ?= 667
export CLOCK_PORT               = clk

# --- synthesis -------------------------------------------------------------
export SYNTH_HIERARCHICAL       = 0
export ABC_AREA                 = 1

# --- floorplan -------------------------------------------------------------
# ASAP7 core cells are far smaller than sky130hd; keep utilization moderate.
export CORE_UTILIZATION         = 45
export CORE_ASPECT_RATIO        = 1
export CORE_MARGIN              = 2

# --- placement -------------------------------------------------------------
export PLACE_DENSITY            = 0.60
export TNS_END_PERCENT          = 100

# --- routing ---------------------------------------------------------------
export ROUTE_EXTRA_SPACE        = 1

# --- STA / signoff ---------------------------------------------------------
# Strict: no negative slack margin games. WNS is reported as-is.
export SETUP_SLACK_MARGIN       = 0

# --- skip RCX extraction (set_extraction_rules_file not in this OpenROAD) -----
export RCX_RULES =
