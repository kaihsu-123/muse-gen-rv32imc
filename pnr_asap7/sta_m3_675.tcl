# Post-synth STA for MUL_STAGES=3 synth at 675ps
set PDIR /home/hatch/workspace/rv32imc-cpu/tools/orfs/flow/platforms/asap7
set RES  /home/hatch/workspace/rv32imc-cpu/tools/orfs/flow/results/asap7/rv32imc_top/base
read_db  $RES/1_synth.odb
read_liberty $PDIR/lib/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.lib.gz
read_liberty $PDIR/lib/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib.gz
read_liberty $PDIR/lib/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.lib.gz
read_liberty $PDIR/lib/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib.gz
read_liberty $PDIR/lib/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib
read_sdc $RES/1_synth.sdc
# SDC already carries set_clock_uncertainty -setup 20 (do NOT double-apply)
report_checks -path_delay max -slack_max -0.5 -digits 4 -fields {slew cap input_pins net fanout} > /home/hatch/workspace/rv32imc-cpu/pnr_asap7/reports/sta_m3_675ps.rpt
report_worst_slack -max -digits 4
report_tns -max -digits 4
exit
