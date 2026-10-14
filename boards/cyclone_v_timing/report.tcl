# SPDX-License-Identifier: MIT
# Worst setup paths and fmax of the CPU-only build at the slow 100 C corner.
package require ::quartus::project
package require ::quartus::sta
project_open spk286_timing -revision spk286_timing
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set_operating_conditions 7_slow_1100mv_100c
update_timing_netlist
report_clock_fmax_summary -file fmax.rpt
report_timing -setup -from_clock clk -to_clock clk -npaths 200 -detail summary -file worst.rpt
report_timing -setup -from_clock clk -to_clock clk -npaths 3 -detail full_path -file worst_full.rpt
delete_timing_netlist
project_close
