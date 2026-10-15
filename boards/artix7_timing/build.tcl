# SPDX-License-Identifier: MIT
# Out-of-context implementation of spk286_native and its timing reports.
# Arguments: PART PERIOD_NS. Run from the frozen run directory (build.sh).
lassign $argv part period

set fd [open sources.txt r]
set sources [split [string trim [read $fd]] "\n"]
close $fd
read_verilog -sv $sources

set fd [open timing.xdc w]
puts $fd "create_clock -name clk -period $period \[get_ports clk\]"
# Out of context, clk is otherwise a plain net; assume a global buffer.
puts $fd "set_property HD.CLK_SRC BUFGCTRL_X0Y0 \[get_ports clk\]"
close $fd
read_xdc -mode out_of_context timing.xdc

synth_design -top spk286_native -part $part -mode out_of_context
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 3 -file timing_summary.rpt
report_utilization -file utilization.rpt
report_timing -setup -max_paths 3 -nworst 1 -file worst_full.rpt

set fd [open worst.csv w]
puts $fd "slack,levels,startpoint,endpoint"
foreach path [get_timing_paths -setup -max_paths 200 -nworst 1] {
    puts $fd [join [list [get_property SLACK $path] [get_property LOGIC_LEVELS $path] \
        [get_property PARENT_CELL [get_property STARTPOINT_PIN $path]] \
        [get_property PARENT_CELL [get_property ENDPOINT_PIN $path]]] ,]
}
close $fd

set fd [open result.txt w]
puts $fd "part $part"
puts $fd "period $period"
puts $fd "wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]"
puts $fd "whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]"
close $fd
