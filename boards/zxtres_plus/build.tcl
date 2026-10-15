# SPDX-License-Identifier: MIT
# Vivado non-project build of the ZXTRES+ demo. Run from the build directory
# prepared by boards/zxtres_plus/build.sh, which holds sources.txt, the .mem
# images and the constraints. Arguments: PART CPU_DIVIDE.
lassign $argv part cpu_divide

set fd [open sources.txt r]
set sources [split [string trim [read $fd]] "\n"]
close $fd
read_verilog -sv $sources
read_mem [glob *.mem]
read_xdc zxtres_demo.xdc

synth_design -top zxtres_demo_top -part $part -include_dirs [list src] \
    -generic CPU_DIVIDE=$cpu_divide
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 5 -file timing_summary.rpt
report_utilization -file utilization.rpt
report_clock_utilization -file clocks.rpt
report_drc -file drc.rpt

set fd [open result.txt w]
puts $fd "part $part"
puts $fd "cpu_divide $cpu_divide"
puts $fd "wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]"
puts $fd "whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]"
close $fd

write_bitstream -force zxtres_demo.bit
