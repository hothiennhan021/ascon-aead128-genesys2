# Gate-level functional simulation + SAIF-based power + static timing
# evidence (buoc 8 trong quy trinh lam viec, xem CLAUDE.md/docs/uarch.md
# muc 7 va docs/BUGS.md).
#
# Ban dau du dinh mo phong TIMING (SDF back-annotation, xem lich su o
# docs/BUGS.md): xelab bao loi 43-3462 "Unable to annotate SDF delays"
# tren moi FDCE vi thu vien unisims_ver di kem ban cai Vivado nay thieu
# specify block day du (module "FDCE_default" khong co bieu thuc do tre
# cho setup/hold/recovery/removal) -- can compile_simlib de tao lai thu
# vien mo phong day du, nhung ngay ca gioi han dung -language verilog
# -library unisim, Vivado 2022.2 van in canh bao 12-5377 va thuc te
# chay rat lau (con dang o buoc "Extracting data from the IP
# repository" sau hon 1 phut) -- chi phi khong tuong xung voi buoc nay.
# Thay bang phuong an du phong (xem docs/BUGS.md):
#
#   1. Functional gate-level sim (write_verilog -mode funcsim, KHONG
#      SDF, khong can thu vien mo phong dac biet) -- chung minh netlist
#      sau dat cho/di day dung chuc nang, chay 20 vector KAT chon loc.
#   2. Cong suat: xuat SAIF tu chinh lan mo phong do (khong can chu
#      thich SDF), nap vao report_power.
#   3. Bang chung timing: report_timing_summary tinh (khong mo phong co
#      tre) tren chinh $post_route_dcp thay cho gate-level timing sim.
#
# CHI mot lan goi Vivado duy nhat cho toan bo buoc nay (mo dcp ->
# report_timing_summary -> xuat netlist funcsim -> xsim -> SAIF ->
# report_power) -- theo yeu cau han che toi da so lan goi Vivado/mo
# phong (xem tb/directed/tb_gatesim.v: chi 20/1089 vector KAT).
#
# Chay bang: vivado -mode batch -source scripts/gatesim.tcl
# hoac:      vivado -mode batch -source scripts/gatesim.tcl -tclargs 2
# (so cuoi la ROUNDS_PER_CYCLE, mac dinh 1 -- phai khop voi RPC da
# dung khi chay "make impl" de co dung reports/post_route_rpc<N>.dcp.
# LUU Y: tb/directed/tb_gatesim.v va kat_gatesim20.hex hien chi co bo 20
# vector cho RPC=1.)

set_param general.maxThreads 8

set rounds_per_cycle 1
if {$argc > 0} {
    set rounds_per_cycle [lindex $argv 0]
}
set rpc_suffix "rpc${rounds_per_cycle}"

set report_dir     reports
set post_route_dcp [file join $report_dir "post_route_${rpc_suffix}.dcp"]
set netlist_v      [file join $report_dir "netlist_funcsim_${rpc_suffix}.v"]
set saif_file      [file join $report_dir "gatesim_${rpc_suffix}.saif"]
set power_rpt      [file join $report_dir "power_${rpc_suffix}.rpt"]
set timing_rpt     [file join $report_dir "timing_summary_${rpc_suffix}.rpt"]

set tb_file   [file normalize tb/directed/tb_gatesim.v]
set glbl_file [file normalize [file join $::env(XILINX_VIVADO) data verilog src glbl.v]]
set snap      "gatesim_${rpc_suffix}_snap"

# --- mo checkpoint da route ---
open_checkpoint $post_route_dcp

# --- (3) bang chung timing tinh, thay cho mo phong co tre ---
report_timing_summary -file $timing_rpt

# --- (1) xuat netlist FUNCTIONAL gate-level (khong SDF) ---
write_verilog -mode funcsim -force -file $netlist_v

# --- bien dich + chay xsim qua exec (khong dung launch_simulation vi
# checkpoint mo bang open_checkpoint khong co project/fileset di kem)
# ---
# 2>@1: gop stderr vao stdout de "exec" khong tu coi bat ky dong stderr
# nao (vd WARNING cua Xilinx tool, thoat ma 0) la loi -- day la hanh vi
# mac dinh cua Tcl "exec". Loi that (thoat ma khac 0) van khien catch
# tra ve khac 0, luc do moi dung script.
proc run_tool {desc cmd} {
    puts "\n=== $desc ==="
    puts "+ $cmd"
    set status [catch {exec {*}$cmd 2>@1} out]
    puts $out
    if {$status} {
        error "$desc THAT BAI (thoat ma khac 0, xem log o tren)"
    }
    return $out
}

run_tool "xvlog netlist gate-level (funcsim)" [list xvlog $netlist_v]
run_tool "xvlog testbench"                    [list xvlog $tb_file]
run_tool "xvlog glbl"                         [list xvlog $glbl_file]

# -debug typical: can thiet de xsim co du "trace information" cho
# log_saif/get_objects trong --tclbatch ben duoi -- thieu co nay xsim
# bao loi 45-10 "compiled without trace information" (da kiem chung
# bang chay thu).
run_tool "xelab" [list xelab -relax -debug typical -L unisims_ver -L secureip \
    work.tb_gatesim work.glbl -s $snap]

# --- (1) chay + (2) thu SAIF trong cung mot lan xsim ---
# xsim (Vivado 2022.2) KHONG co switch dong lenh "-saif"/"-saif_scope"
# ("Unexpected option encountered : saif", da kiem chung bang chay
# thu) -- phai dieu khien SAIF bang lenh Tcl open_saif/log_saif/
# close_saif ben trong mot --tclbatch, thay cho "-R".
set xsim_tclbatch [file join $report_dir "gatesim_${rpc_suffix}_run.tcl"]
set fh [open $xsim_tclbatch w]
puts $fh "open_saif $saif_file"
puts $fh {log_saif [get_objects -r *]}
puts $fh "run all"
puts $fh "close_saif"
puts $fh "quit"
close $fh

set xsim_out [run_tool "xsim (chay mo phong + thu SAIF)" \
    [list xsim $snap --tclbatch $xsim_tclbatch]]

if {![string match "*PASSED ALL*" $xsim_out]} {
    error "tb_gatesim KHONG in ra PASSED ALL -- xem log xsim o tren truoc khi doc SAIF/power"
}
if {![file exists $saif_file]} {
    error "Khong thay $saif_file sau khi chay xsim"
}

# --- (2) nap SAIF vao thiet ke dang mo va bao cao cong suat ---
# -strip_path (khong phai -scope, da kiem chung bang chay thu: "Unknown
# option '-scope'"): bo tien to "tb_gatesim/dut" khoi moi duong dan
# trong SAIF de khop voi ten noi bo cua $post_route_dcp (top-level
# khong co tien to testbench).
read_saif -strip_path tb_gatesim/dut $saif_file
report_power -file $power_rpt

puts "\n=== GATESIM DONE: $post_route_dcp (ROUNDS_PER_CYCLE=$rounds_per_cycle) ==="
puts "netlist (funcsim, khong SDF)=$netlist_v"
puts "saif=$saif_file"
puts "power report=$power_rpt"
puts "timing summary (tinh)=$timing_rpt"
