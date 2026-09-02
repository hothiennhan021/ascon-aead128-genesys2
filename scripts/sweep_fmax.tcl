# Quet Fmax bang cach thu nhieu chu ky dong ho tren reports/post_synth.dcp
# (buoc 7 trong quy trinh lam viec, xem CLAUDE.md). Chua chay o phien
# nay - chi viet script, chua goi Vivado.
#
# Chay bang: vivado -mode batch -source scripts/sweep_fmax.tcl
# (can chay "make synth" truoc de co reports/post_synth.dcp)
#
# Voi moi chu ky trong danh sach: mo lai post_synth.dcp (khong ke thua
# placement/routing tu lan thu truoc, moi phep thu doc lap), dat lai
# create_clock, chay opt_design -> place_design -> phys_opt_design ->
# route_design, doc WNS qua get_property SLACK tren get_timing_paths
# (duong xau nhat, huong setup), tinh Fmax = 1000/(period - WNS) MHz.
# Luu post_route.dcp cho chu ky NHO NHAT (nhanh nhat) van con WNS >= 0.

set report_dir     reports
set post_synth_dcp [file join $report_dir post_synth.dcp]
set post_route_dcp [file join $report_dir post_route.dcp]
set clock_port      pclk
set clock_name      pclk

set periods {10.0 8.0 6.0 5.8 5.6 5.4 5.2 5.0 4.5 4.0 3.5 3.0}

file mkdir $report_dir

set best_period ""
set results {}

foreach period $periods {
    open_checkpoint $post_synth_dcp

    create_clock -period $period -name $clock_name [get_ports $clock_port]

    opt_design
    place_design
    phys_opt_design
    route_design

    set wns  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set fmax [expr {1000.0 / ($period - $wns)}]
    set status [expr {$wns >= 0 ? "PASS" : "FAIL"}]

    lappend results [list $period $wns $fmax $status]

    if {$wns >= 0} {
        set best_period $period
        write_checkpoint -force $post_route_dcp
    }

    close_design
}

puts "=== BANG QUET FMAX ==="
puts [format "%-12s %-10s %-12s %s" "Period(ns)" "WNS(ns)" "Fmax(MHz)" "Status"]
foreach r $results {
    lassign $r period wns fmax status
    puts [format "%-12.3f %-10.3f %-12.2f %s" $period $wns $fmax $status]
}

if {$best_period ne ""} {
    puts "=== Da luu $post_route_dcp cho chu ky $best_period ns (nho nhat con WNS >= 0) ==="
} else {
    puts "=== KHONG CO chu ky nao dat WNS >= 0 - khong luu post_route.dcp ==="
}
