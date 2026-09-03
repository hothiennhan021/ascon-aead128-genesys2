# Makefile cho do an ASCON-AEAD128 - phien ban Windows
# Yeu cau: python, iverilog, vvp, make trong PATH
# LUU Y: cac dong lenh phai bat dau bang ky tu TAB, khong phai dau cach

SHELL := cmd.exe
.SHELLFLAGS := /c

PY       := python
IVERILOG := iverilog
VVP      := vvp

RTL_CORE := rtl/core/ascon_sbox.v rtl/core/ascon_linear.v \
            rtl/core/ascon_round.v rtl/core/ascon_perm.v \
            rtl/core/ascon_aead_fsm.v
RTL_IP   := rtl/ip/ascon_apb.v
BUILD    := build
KAT      := vectors/LWC_AEAD_KAT_128_128.txt

# So vong hoan vi chay moi chu ky trong ascon_perm (1 = kien truc goc,
# 2 = kien truc khao sat thu hai, xem docs/uarch.md muc 6). Ghi de
# bang: make regress RPC=2 -- truyen thang xuong macro tien xu ly
# `ROUNDS_PER_CYCLE (xem rtl/core/ascon_perm.v), khong dung defparam/
# tham so dong lenh.
RPC := 1

# Part Vivado dung cho synth/impl/report (mac dinh Artix-7 tren Basys
# 3). Ghi de bang: make synth PART=xc7k325tffg900-2 -- xem
# docs/uarch.md muc 7 "Khao sat theo dong chip".
PART := xc7a35tcpg236-1

.PHONY: all model unit kat regress synth impl report gatesim clean help

help:
	@echo.
	@echo   make model     - chay mo hinh Python voi test vector NIST
	@echo   make unit      - test tung module RTL
	@echo   make kat       - chay test vector qua RTL
	@echo   make regress   - chay toan bo testbench
	@echo   make synth     - tong hop Out-of-Context bang Vivado
	@echo   make impl      - implement va quet Fmax
	@echo   make report    - bao cao PPA sau route (report_utilization -hierarchical)
	@echo   make gatesim   - mo phong gate-level functional + do cong suat (SAIF) + timing tinh
	@echo   make clean     - xoa file tam
	@echo.
	@echo   Them RPC=2 vao unit/kat/regress/synth de chay kien truc
	@echo   ROUNDS_PER_CYCLE=2 (mac dinh RPC=1) - xem docs/uarch.md muc 6.
	@echo   Them PART=xc7k325tffg900-2 vao synth/impl/report de doi part
	@echo   Vivado (mac dinh xc7a35tcpg236-1) - xem docs/uarch.md muc 7.
	@echo.

all: model regress

# --- Buoc 2: mo hinh tham chieu ---
model:
	$(PY) model/ascon_model.py --run-kat $(KAT)

# --- Buoc 5a: test tung module ---
# -DROUNDS_PER_CYCLE=$(RPC): dinh nghia macro tien xu ly doc boi
# rtl/core/ascon_perm.v (va tb/unit/tb_perm.v) de chon kien truc,
# xem docs/uarch.md muc 6.
unit:
	@if not exist $(BUILD) mkdir $(BUILD)
	$(IVERILOG) -g2005 -I tb/unit -o $(BUILD)/tb_sbox.vvp rtl/core/ascon_sbox.v rtl/core/ascon_linear.v tb/unit/tb_sbox.v
	$(VVP) $(BUILD)/tb_sbox.vvp
	$(IVERILOG) -g2005 -I tb/unit -o $(BUILD)/tb_linear.vvp rtl/core/ascon_sbox.v rtl/core/ascon_linear.v tb/unit/tb_linear.v
	$(VVP) $(BUILD)/tb_linear.vvp
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_round.vvp $(RTL_CORE) tb/unit/tb_round.v
	$(VVP) $(BUILD)/tb_round.vvp
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_perm.vvp $(RTL_CORE) tb/unit/tb_perm.v
	$(VVP) $(BUILD)/tb_perm.vvp

# --- Buoc 5b: test vector NIST qua RTL ---
kat:
	@if not exist $(BUILD) mkdir $(BUILD)
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_aead.vvp $(RTL_CORE) tb/directed/tb_aead.v
	$(VVP) $(BUILD)/tb_aead.vvp
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_apb.vvp $(RTL_CORE) $(RTL_IP) tb/sva/apb_checker.v tb/directed/tb_apb.v
	$(VVP) $(BUILD)/tb_apb.vvp

# --- Buoc 5: cong kiem soat chinh ---
regress: unit kat
	@echo === REGRESSION DONE ===

# --- Buoc 6: tong hop Out-of-Context ---
# RPC truyen vao synth_ooc.tcl qua -tclargs, dung synth_design
# -verilog_define ROUNDS_PER_CYCLE (cung macro doc boi
# rtl/core/ascon_perm.v khi mo phong -- xem scripts/synth_ooc.tcl va
# docs/uarch.md muc 6). Checkpoint/report ra co hau to _rpc<N> de hai
# kien truc khong ghi de len nhau.
synth:
	vivado -mode batch -source scripts/synth_ooc.tcl -tclargs $(RPC) $(PART)

# --- Buoc 7: implement va quet Fmax (can co reports/post_synth_rpc$(RPC).dcp) ---
impl: synth
	vivado -mode batch -source scripts/sweep_fmax.tcl -tclargs $(RPC) $(PART)

# --- Buoc 7: bao cao PPA sau route (can co reports/post_route_rpc$(RPC).dcp) ---
report:
	vivado -mode batch -source scripts/report_ppa.tcl -tclargs $(RPC) $(PART)

# --- Buoc 8: gate-level functional sim + do cong suat bang SAIF +
# bang chung timing tinh (can co reports/post_route_rpc$(RPC).dcp; hien
# tb/directed/tb_gatesim.v va .hex 20 vector chi khop RPC=1 -- xem ghi
# chu dau scripts/gatesim.tcl va docs/BUGS.md ve viec khong dung duoc
# gate-level TIMING sim/SDF o ban cai Vivado nay) ---
gatesim:
	vivado -mode batch -source scripts/gatesim.tcl -tclargs $(RPC)

clean:
	@if exist $(BUILD) rmdir /s /q $(BUILD)
	@del /q *.vcd 2>nul
	@del /q vivado*.log vivado*.jou 2>nul
	@if exist .Xil rmdir /s /q .Xil
	@echo Cleaned.
