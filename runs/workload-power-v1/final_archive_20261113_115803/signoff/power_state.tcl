set ROOT "/workspaces/awake_2.0"
set SKY130 "/workspaces/pdks/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A"

set RUN "$ROOT/runs/signoff-repair-v2"
set OUT "$ROOT/runs/workload-power-v1"

# Supplied separately for each state.
set VCD $::env(VCD_FILE)
set STATE $::env(STATE_NAME)

set TECH_LEF "$SKY130/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef"
set CELL_LEF "$SKY130/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef"
set EF_LEF "$SKY130/libs.ref/sky130_fd_sc_hd/lef/sky130_ef_sc_hd.lef"

set LIB "$SKY130/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"

set NETLIST "$RUN/54-openroad-fillinsertion/agrisense_ipms_top.nl.v"
set SDC "$RUN/54-openroad-fillinsertion/agrisense_ipms_top.sdc"
set SPEF "$RUN/56-openroad-rcx/nom/agrisense_ipms_top.nom.spef"

set REPORT_DIR "$OUT/reports/per-state"
file mkdir $REPORT_DIR

puts "========== AWAKE STATE POWER =========="
puts "STATE: $STATE"
puts "VCD: $VCD"

read_lef -tech $TECH_LEF
read_lef -library $CELL_LEF
read_lef -library $EF_LEF

read_liberty $LIB
read_verilog $NETLIST
link_design agrisense_ipms_top

read_sdc $SDC
read_spef $SPEF

read_vcd -scope tb_power_state/uut $VCD

report_parasitic_annotation \
    -report_unannotated \
    > "$REPORT_DIR/${STATE}_parasitic.rpt"

report_power -digits 8 \
    > "$REPORT_DIR/${STATE}_power.rpt"

puts "========== STATE POWER COMPLETE: $STATE =========="