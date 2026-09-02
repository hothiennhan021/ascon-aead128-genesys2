# Bao cao PPA sau route (buoc 7 trong quy trinh lam viec, xem
# CLAUDE.md). Mo reports/post_route.dcp - checkpoint da route, luu boi
# sweep_fmax.tcl cho chu ky NHO NHAT con dat WNS >= 0 - xuat
# report_utilization -hierarchical (de tach LUT/FF cua loi Ascon,
# duoi u_fsm, khoi lop giao dien APB) va in lai WNS/Fmax dat duoc o
# chu ky da luu, dung lam du lieu dien vao reports/ppa.csv.
#
# Chay bang: vivado -mode batch -source scripts/report_ppa.tcl
# (can chay "make impl" truoc de co reports/post_route.dcp)

set report_dir reports

open_checkpoint [file join $report_dir post_route.dcp]

report_utilization -hierarchical \
    -file [file join $report_dir report_utilization_route_hierarchical.rpt]

report_timing -max_paths 5 -sort_by group \
    -file [file join $report_dir timing_critical.rpt]

set clk    [get_clocks pclk]
set period [get_property PERIOD $clk]
set wns    [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax   [expr {1000.0 / ($period - $wns)}]

puts "=== PPA sau route (reports/post_route.dcp) ==="
puts [format "period=%.3f ns   wns=%.3f ns   fmax=%.2f MHz" $period $wns $fmax]
