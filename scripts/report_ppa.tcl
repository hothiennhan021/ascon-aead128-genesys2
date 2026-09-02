# Bao cao PPA sau route (buoc 7 trong quy trinh lam viec, xem
# CLAUDE.md). Mo reports/post_route_rpc<N>.dcp - checkpoint da route,
# luu boi sweep_fmax.tcl cho chu ky NHO NHAT con dat WNS >= 0 - xuat
# report_utilization -hierarchical (de tach LUT/FF cua loi Ascon,
# duoi u_fsm, khoi lop giao dien APB) va in lai WNS/Fmax dat duoc o
# chu ky da luu, dung lam du lieu dien vao reports/ppa.csv.
#
# Chay bang: vivado -mode batch -source scripts/report_ppa.tcl
# hoac:      vivado -mode batch -source scripts/report_ppa.tcl -tclargs 2
# (so cuoi la ROUNDS_PER_CYCLE, mac dinh 1 -- phai khop voi RPC da
# dung khi chay "make impl" de co dung reports/post_route_rpc<N>.dcp.
# make report RPC=2 goi dung cach nay. Hau to rpc<N> tren moi report
# de hai kien truc khong ghi de len nhau.)

set rounds_per_cycle 1
if {$argc > 0} {
    set rounds_per_cycle [lindex $argv 0]
}
set rpc_suffix "rpc${rounds_per_cycle}"

set report_dir  reports
set post_route_dcp [file join $report_dir "post_route_${rpc_suffix}.dcp"]

open_checkpoint $post_route_dcp

report_utilization -hierarchical \
    -file [file join $report_dir "report_utilization_route_hierarchical_${rpc_suffix}.rpt"]

report_timing -max_paths 5 -sort_by group \
    -file [file join $report_dir "timing_critical_${rpc_suffix}.rpt"]

set clk    [get_clocks pclk]
set period [get_property PERIOD $clk]
set wns    [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax   [expr {1000.0 / ($period - $wns)}]

puts "=== PPA sau route ($post_route_dcp) ==="
puts [format "period=%.3f ns   wns=%.3f ns   fmax=%.2f MHz" $period $wns $fmax]
