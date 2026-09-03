# Bao cao PPA sau route (buoc 7 trong quy trinh lam viec, xem
# CLAUDE.md). Mo reports/post_route_rpc<N>.dcp - checkpoint da route,
# luu boi sweep_fmax.tcl cho chu ky NHO NHAT con dat WNS >= 0 - xuat
# report_utilization -hierarchical (de tach LUT/FF cua loi Ascon,
# duoi u_fsm, khoi lop giao dien APB) va in lai WNS/Fmax dat duoc o
# chu ky da luu, dung lam du lieu dien vao reports/ppa.csv.
#
# Chay bang: vivado -mode batch -source scripts/report_ppa.tcl
# hoac:      vivado -mode batch -source scripts/report_ppa.tcl -tclargs 2
# hoac:      vivado -mode batch -source scripts/report_ppa.tcl -tclargs 1 xc7k325tffg900-2
# (arg 1 la ROUNDS_PER_CYCLE, mac dinh 1; arg 2 la ten part Vivado, mac
# dinh xc7a35tcpg236-1 -- ca hai phai khop voi cap da dung khi chay
# "make impl" de co dung reports/post_route_<suffix>.dcp. make report
# RPC=2 PART=... goi dung cach nay. Hau to tren moi report de cac kien
# truc/part khong ghi de len nhau -- cung logic voi scripts/synth_ooc.tcl.)

set_param general.maxThreads 8

set default_part xc7a35tcpg236-1
set part_name    $default_part

set rounds_per_cycle 1
if {$argc > 0} {
    set rounds_per_cycle [lindex $argv 0]
}
if {$argc > 1} {
    set part_name [lindex $argv 1]
}

if {$part_name eq $default_part} {
    set rpc_suffix "rpc${rounds_per_cycle}"
} else {
    set rpc_suffix "${part_name}_rpc${rounds_per_cycle}"
}

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
