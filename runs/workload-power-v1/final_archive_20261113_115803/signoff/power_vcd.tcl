
# AWAKE - Gate-level VCD power characterization
# SKY130A HD | Nominal TT | 25C | 1.80V | 50MHz

set ROOT "/workspaces/awake_2.0"
set SKY130 "/workspaces/pdks/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A"

set RUN "$ROOT/runs/signoff-repair-v2"
set OUT "$ROOT/runs/workload-power-v1"

# Physical technology and standard-cell LEF
set TECH_LEF "$SKY130/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef"
set CELL_LEF "$SKY130/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef"

# Matching signoff files
set LIB "$SKY130/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
set NETLIST "$RUN/54-openroad-fillinsertion/agrisense_ipms_top.nl.v"
set SDC "$RUN/54-openroad-fillinsertion/agrisense_ipms_top.sdc"
set SPEF "$RUN/56-openroad-rcx/nom/agrisense_ipms_top.nom.spef"
set VCD "$OUT/simulation/workload.vcd"

puts "========== AWAKE VCD POWER ANALYSIS =========="

puts "STEP 1: Read nominal technology LEF"
read_lef -tech $TECH_LEF

puts "STEP 2: Read HD standard-cell LEF"
read_lef -library $CELL_LEF
read_lef -library "$SKY130/libs.ref/sky130_fd_sc_hd/lef/sky130_ef_sc_hd.lef"

puts "STEP 3: Read nominal TT Liberty"
read_liberty $LIB

puts "STEP 4: Read final gate-level netlist"
read_verilog $NETLIST

puts "STEP 5: Link design"
link_design agrisense_ipms_top

puts "STEP 6: Read final signoff SDC"
read_sdc $SDC

puts "STEP 7: Read nominal SPEF"
read_spef $SPEF

puts "STEP 8: Read gate-level VCD activity"
puts "VCD scope: tb_power_workload/uut"
read_vcd -scope tb_power_workload/uut $VCD

puts "STEP 9: Report parasitic annotation"
report_parasitic_annotation -report_unannotated \
    > "$OUT/reports/parasitic_annotation.rpt"

puts "STEP 10: Calculate VCD-annotated power"
report_power -digits 8 \
    > "$OUT/reports/power_vcd.rpt"

puts "========== POWER REPORT =========="
exec cat "$OUT/reports/power_vcd.rpt"

puts "========== ANALYSIS COMPLETE =========="
exit
