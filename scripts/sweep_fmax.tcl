# Quet Fmax hai giai doan tren checkpoint post-synth (buoc 7 trong quy
# trinh lam viec, xem CLAUDE.md).
#
# Chay bang: vivado -mode batch -source scripts/sweep_fmax.tcl
# hoac:      vivado -mode batch -source scripts/sweep_fmax.tcl -tclargs 2
# (so cuoi la ROUNDS_PER_CYCLE, mac dinh 1 -- phai khop voi RPC da
# dung khi chay "make synth" de co dung reports/post_synth_rpc<N>.dcp.
# make impl RPC=2 goi dung cach nay.)
#
# Thuat toan (thay cho quet 12-18 chu ky co dinh -- qua cham voi kien
# truc co duong to hop dai nhu ROUNDS_PER_CYCLE=4, moi luot route_design
# co the toi vai phut):
#
#   Giai doan THO -- 3 chu ky {10.0 7.0 5.5} ns, moi luot: opt_design
#   -> place_design (KHONG phys_opt_design, KHONG route_design) -> doc
#   WNS UOC LUONG (sau place, truoc route -- Vivado van tinh duoc
#   timing tu mo hinh RC uoc luong theo vi tri, chua phai dinh tuyen
#   that). Giai doan nay chi de KHOANH VUNG diem MET/VIOLATED, khong
#   can so chinh xac nen khong bao gio chay route_design (khac ban
#   truoc: truoc day van route khi uoc luong khong qua te -- bo hoan
#   toan de giai doan tho luon nhanh, on dinh).
#
#   Tinh diem giua cho giai doan MIN: trong 3 chu ky THO, chon chu ky
#   co |WNS uoc luong| nho nhat (gan diem MET/VIOLATED nhat) va suy ra
#   do tre thuc te uoc luong center = period - wns_est (vi do tre
#   duong toi han gan nhu khong doi theo chu ky dat, period=center la
#   diem WNS~0).
#
#   Giai doan MIN -- lam tron center ve boi so 0.1 ns gan nhat, roi
#   quet 4 chu ky lien tiep cach nhau 0.1 ns quanh do:
#   {round-0.2, round-0.1, round, round+0.1} (vi du center=5.587 ->
#   round=5.6 -> quet {5.4, 5.5, 5.6, 5.7}). Ly do lam tron: ca ba kien
#   truc (RPC=1/2/4) phai do tren cung mot luoi chu ky boi so 0.1 ns de
#   bang so sanh trong bao cao nhat quan, de doc. Moi chu ky: opt_design
#   -> place_design -> phys_opt_design (GIU o giai doan nay de chot so
#   lieu chinh xac) -> route_design -> WNS/Fmax that.
#
#   Buoc du phong: neu ca 4 chu ky MIN deu FAIL (WNS uoc luong sau
#   place khong du chinh xac), mo rong dan tung +0.1 ns MOT LAN
#   (round+0.2, +0.3, +0.4, ...) bang dung pipeline day du (opt_design
#   -> place_design -> phys_opt_design -> route_design), dung ngay khi
#   gap PASS, cho toi tran +2.0 ns thi bo cuoc. Chi mo rong ve phia lon
#   hon (chu ky dai hon, de PASS hon) vi uoc luong sau place thuong LAC
#   QUAN hon thuc te (WNS that sau route thap hon WNS uoc luong sau
#   place) -- sai so nay KHONG co dinh, ROUNDS_PER_CYCLE cang lon
#   duong to hop cang dai thi sai so cang lon (do voi RPC=2: ~0.2-0.3
#   ns; RPC=4: toi ~0.8-1.0 ns) nen vong lap mo rong thay vi mot buoc
#   nhay co dinh.
#
#   CHI giai doan MIN (ke ca cac chu ky du phong mo rong) moi duoc chot
#   lam ket qua cuoi (giai doan THO khong route_design nen khong co so
#   that de chot). Luu post_route_rpc<N>.dcp cho chu ky NHO NHAT van
#   con WNS >= 0.

set_param general.maxThreads 8

set rounds_per_cycle 1
if {$argc > 0} {
    set rounds_per_cycle [lindex $argv 0]
}
set rpc_suffix "rpc${rounds_per_cycle}"

set report_dir     reports
set post_synth_dcp [file join $report_dir "post_synth_${rpc_suffix}.dcp"]
set post_route_dcp [file join $report_dir "post_route_${rpc_suffix}.dcp"]
set clock_port      pclk
set clock_name      pclk

set coarse_periods {10.0 7.0 5.5}

file mkdir $report_dir

set best_period ""
set results {}

# ---- giai doan THO (chi opt_design + place_design, khong route_design) ---
set center_delay   ""
set best_abs_wns   ""

foreach period $coarse_periods {
    open_checkpoint $post_synth_dcp
    create_clock -period $period -name $clock_name [get_ports $clock_port]

    opt_design
    place_design

    set wns_est [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]

    puts [format "COARSE %-8.3f wns_est=%-9.3f (uoc luong sau place, khong route_design)" $period $wns_est]
    lappend results [list $period $wns_est "" "COARSE-est"]

    if {$best_abs_wns eq "" || abs($wns_est) < $best_abs_wns} {
        set best_abs_wns [expr {abs($wns_est)}]
        set center_delay [expr {$period - $wns_est}]
    }

    close_design
}

# lam tron center ve boi so 0.1 ns gan nhat
set rounded_center [expr {round($center_delay * 10) / 10.0}]

puts [format "=== Diem giua cho giai doan MIN: %.3f ns uoc luong -> lam tron %.1f ns (buoc 0.1 ns) ===" \
    $center_delay $rounded_center]

# ---- giai doan MIN (opt_design -> place_design -> phys_opt_design -> route_design) ---
proc run_fine_period {period post_synth_dcp post_route_dcp clock_name clock_port \
                       resultsVar bestPeriodVar} {
    upvar 1 $resultsVar results
    upvar 1 $bestPeriodVar best_period

    open_checkpoint $post_synth_dcp
    create_clock -period $period -name $clock_name [get_ports $clock_port]

    opt_design
    place_design
    phys_opt_design
    route_design

    set wns  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set fmax [expr {1000.0 / ($period - $wns)}]
    set status [expr {$wns >= 0 ? "PASS" : "FAIL"}]

    puts [format "FINE   %-8.3f wns=%-9.3f fmax=%-9.2f %s" $period $wns $fmax $status]
    lappend results [list $period $wns $fmax "FINE-$status"]

    if {$wns >= 0} {
        if {$best_period eq "" || $period < $best_period} {
            set best_period $period
            write_checkpoint -force $post_route_dcp
        }
    }

    close_design
    return $wns
}

foreach off {-0.2 -0.1 0.0 0.1} {
    run_fine_period [expr {$rounded_center + $off}] $post_synth_dcp $post_route_dcp \
        $clock_name $clock_port results best_period
}

if {$best_period eq ""} {
    puts "=== Ca 4 chu ky MIN dau tien deu FAIL -- mo rong dan +0.1 ns/lan (toi da +2.0 ns) cho toi khi PASS ==="
    for {set k 2} {$k <= 20 && $best_period eq ""} {incr k} {
        set off [expr {$k / 10.0}]
        run_fine_period [expr {$rounded_center + $off}] $post_synth_dcp $post_route_dcp \
            $clock_name $clock_port results best_period
    }
    if {$best_period eq ""} {
        puts "=== Van khong PASS sau khi mo rong toi +2.0 ns -- kien truc nay can xem lai luoi THO ==="
    }
}

puts "=== BANG QUET FMAX (thau gian doan THO + MIN) ==="
puts [format "%-8s %-12s %-10s %-12s %s" "Giai" "Period(ns)" "WNS(ns)" "Fmax(MHz)" "Status"]
foreach r $results {
    lassign $r period wns fmax status
    if {$fmax eq ""} {
        puts [format "%-8s %-12.3f %-10.3f %-12s %s" "-" $period $wns "-" $status]
    } else {
        puts [format "%-8s %-12.3f %-10.3f %-12.2f %s" "-" $period $wns $fmax $status]
    }
}

if {$best_period ne ""} {
    puts "=== Da luu $post_route_dcp cho chu ky $best_period ns (nho nhat con WNS >= 0) ==="
} else {
    puts "=== KHONG CO chu ky nao dat WNS >= 0 - khong luu post_route.dcp ==="
}
