open_checkpoint reports/post_route.dcp

report_timing_summary -file reports/timing_summary.rpt
report_timing -max_paths 5 -sort_by group -file reports/timing_critical.rpt
report_utilization -file reports/util_route.rpt
report_utilization -hierarchical -file reports/util_route_hier.rpt

# in nhanh ra man hinh
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS = $wns ns"
puts "LUT = [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]"
puts "FF  = [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]"

exit