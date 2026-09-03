# Tong hop Out-of-Context cho rtl/ip/ascon_apb.v (buoc 6 trong quy
# trinh lam viec, xem CLAUDE.md).
#
# Chay bang: vivado -mode batch -source scripts/synth_ooc.tcl
# hoac:      vivado -mode batch -source scripts/synth_ooc.tcl -tclargs 2
# (so cuoi la ROUNDS_PER_CYCLE truyen qua read_verilog -define, doc boi
# macro tien xu ly `ROUNDS_PER_CYCLE trong rtl/core/ascon_perm.v, mac
# dinh 1 -- xem docs/uarch.md muc 6. make synth/impl RPC=2 goi dung
# cach nay.)

set_param general.maxThreads 8

set part_name   xc7a35tcpg236-1
set top_module  ascon_apb
set report_dir  reports

set rounds_per_cycle 1
if {$argc > 0} {
    set rounds_per_cycle [lindex $argv 0]
}

# Hau to theo RPC de hai kien truc khong ghi de checkpoint/report cua
# nhau (can giu ca hai de chup anh bao cao va doi chieu ve sau).
set rpc_suffix "rpc${rounds_per_cycle}"

set rtl_files {
    rtl/core/ascon_sbox.v
    rtl/core/ascon_linear.v
    rtl/core/ascon_round.v
    rtl/core/ascon_perm.v
    rtl/core/ascon_aead_fsm.v
    rtl/ip/ascon_apb.v
}
set xdc_file constraints/ascon_apb_ooc.xdc

file mkdir $report_dir

read_verilog $rtl_files
read_xdc $xdc_file

# -verilog_define (khong phai read_verilog -define): che do non-project
# batch nhu o day khong co fileset, nen read_verilog -define bao loi
# "only supported when is_compile_unit_mode is enabled on the source
# fileset" -- synth_design co tuy chon rieng cho macro trong che do
# nay.
synth_design -top $top_module -part $part_name -mode out_of_context \
    -verilog_define ROUNDS_PER_CYCLE=$rounds_per_cycle

report_utilization -file [file join $report_dir "report_utilization_${rpc_suffix}.rpt"]
# -hierarchical: tach rieng tai nguyen cua u_fsm (rtl/core/) khoi
# phan giao dien APB (rtl/ip/ascon_apb.v) trong cung mot bao cao.
report_utilization -hierarchical -file [file join $report_dir "report_utilization_hierarchical_${rpc_suffix}.rpt"]
write_checkpoint -force [file join $report_dir "post_synth_${rpc_suffix}.dcp"]

puts "=== SYNTH OOC DONE: $top_module tren $part_name (ROUNDS_PER_CYCLE=$rounds_per_cycle) ==="
