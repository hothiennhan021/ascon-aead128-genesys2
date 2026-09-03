# Tong hop, implement va xuat bitstream cho demo board Genesys 2
# (rtl/demo/top_board.v tren xc7k325tffg900-2). KHAC voi
# scripts/synth_ooc.tcl (buoc 6, Out-of-Context de do PPA cua rieng
# rtl/ip/ascon_apb.v): day la mot thiet ke top-level day du, co IBUFDS/
# MMCME2_BASE/IO that, dinh nap len board thuc -- nen tong hop KHONG
# o che do out_of_context.
#
# Chay bang: vivado -mode batch -source scripts/build_bitstream.tcl
# (make bitstream goi dung cach nay).
#
# LUU Y: script nay chua duoc chay trong phien tao ra no -- moi chi
# viet code va kiem chung tung khoi bang tb/directed/tb_top_board.v
# qua Icarus Verilog. Truoc khi nap bitstream len board that, chay lai
# toan bo script nay va doc ky report_timing_summary/report_drc.

set_param general.maxThreads 8

set part_name  xc7k325tffg900-2
set top_module top_board
set report_dir reports
set out_dir    build

set rtl_files {
    rtl/core/ascon_sbox.v
    rtl/core/ascon_linear.v
    rtl/core/ascon_round.v
    rtl/core/ascon_perm.v
    rtl/core/ascon_aead_fsm.v
    rtl/ip/ascon_apb.v
    rtl/demo/uart_rx.v
    rtl/demo/uart_tx.v
    rtl/demo/apb_master.v
    rtl/demo/cmd_fsm.v
    rtl/demo/top_board.v
}
set xdc_file constraints/top_genesys2.xdc

file mkdir $report_dir
file mkdir $out_dir

read_verilog $rtl_files
read_xdc $xdc_file

# Tong hop day du (khong -mode out_of_context): day la top-level that
# se nap len board, khac voi IP tach roi trong scripts/synth_ooc.tcl.
# Khong truyen ROUNDS_PER_CYCLE qua -verilog_define -- rtl/core/
# ascon_perm.v mac dinh ROUNDS_PER_CYCLE=1 khi khong co macro, dung
# kien truc da do Fmax=304.04 MHz tren chinh part nay
# (reports/ppa_multidevice.csv), thua nhieu bien so cho muc tieu
# 100 MHz chon trong rtl/demo/top_board.v.
synth_design -top $top_module -part $part_name

report_utilization -file [file join $report_dir "report_utilization_board.rpt"]
write_checkpoint -force [file join $out_dir "post_synth_board.dcp"]

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file [file join $report_dir "timing_summary_board.rpt"]
report_utilization -file [file join $report_dir "report_utilization_route_board.rpt"]
write_checkpoint -force [file join $out_dir "post_route_board.dcp"]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "=== BUILD BITSTREAM: WNS sau route = $wns ns (muc tieu 100 MHz) ==="
if {$wns < 0} {
    puts "*** CANH BAO: WNS < 0 -- vi pham timing, KHONG nap bitstream nay len board thuc ***"
}

write_bitstream -force [file join $out_dir "top_board.bit"]

puts "=== BUILD BITSTREAM DONE: [file join $out_dir top_board.bit] ==="
