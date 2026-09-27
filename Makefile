# Makefile cho do an ASCON-AEAD128 - chay duoc tren Windows (cmd.exe)
# lan Linux/macOS (sh).
# Yeu cau: python, iverilog, vvp, make trong PATH
# LUU Y: cac dong lenh phai bat dau bang ky tu TAB, khong phai dau cach

ifeq ($(OS),Windows_NT)
SHELL := cmd.exe
.SHELLFLAGS := /c
PY         := python
MKBUILD     = if not exist $(BUILD) mkdir $(BUILD)
ECHO_BLANK := echo.
else
PY         := python3
MKBUILD     = mkdir -p $(BUILD)
ECHO_BLANK := echo
endif

IVERILOG := iverilog
VVP      := vvp
# chay mot file .vvp, in log, tra ma loi != 0 neu co dong "FAIL..." hoac
# mo phong khong toi $finish -- de make dung lai ngay khi co test hong
RUN      := $(PY) scripts/run_sim.py

RTL_CORE := rtl/core/ascon_sbox.v rtl/core/ascon_linear.v \
            rtl/core/ascon_round.v rtl/core/ascon_perm.v \
            rtl/core/ascon_aead_fsm.v
RTL_IP   := rtl/ip/ascon_apb.v
RTL_DEMO := rtl/demo/uart_rx.v rtl/demo/uart_tx.v rtl/demo/apb_master.v \
            rtl/demo/cmd_fsm.v rtl/demo/top_board.v
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

.PHONY: all model unit kat regress regress_all hexcheck synth impl report gatesim demo_sim bitstream clean help

help:
	@$(ECHO_BLANK)
	@echo   make model     - chay mo hinh Python voi test vector NIST
	@echo   make unit      - test tung module RTL
	@echo   make kat       - chay test vector qua RTL
	@echo   make regress   - chay toan bo testbench (dung lai neu co test FAIL)
	@echo   make regress_all - regress cho ca RPC=1, 2, 4
	@echo   make hexcheck  - kiem tra tb/directed/kat_128_128.hex khop file NIST
	@echo   make synth     - tong hop Out-of-Context bang Vivado
	@echo   make impl      - implement va quet Fmax
	@echo   make report    - bao cao PPA sau route (report_utilization -hierarchical)
	@echo   make gatesim   - mo phong gate-level functional + do cong suat (SAIF) + timing tinh
	@echo   make demo_sim  - mo phong rtl/demo/top_board.v (UART BFM + vai vector KAT) bang Icarus
	@echo   make bitstream - tong hop day du + implement + xuat bitstream demo Genesys 2
	@echo   make clean     - xoa file tam
	@$(ECHO_BLANK)
	@echo   Them RPC=2 vao unit/kat/regress/synth de chay kien truc
	@echo   ROUNDS_PER_CYCLE=2 (mac dinh RPC=1) - xem docs/uarch.md muc 6.
	@echo   Them PART=xc7k325tffg900-2 vao synth/impl/report de doi part
	@echo   Vivado (mac dinh xc7a35tcpg236-1) - xem docs/uarch.md muc 7.
	@$(ECHO_BLANK)

all: model hexcheck regress

# --- Buoc 2: mo hinh tham chieu ---
model:
	$(PY) model/ascon_model.py --run-kat $(KAT)

# --- Buoc 5a: test tung module ---
# -DROUNDS_PER_CYCLE=$(RPC): dinh nghia macro tien xu ly doc boi
# rtl/core/ascon_perm.v (va tb/unit/tb_perm.v) de chon kien truc,
# xem docs/uarch.md muc 6.
unit:
	@$(MKBUILD)
	$(IVERILOG) -g2005 -I tb/unit -o $(BUILD)/tb_sbox.vvp rtl/core/ascon_sbox.v rtl/core/ascon_linear.v tb/unit/tb_sbox.v
	$(RUN) $(BUILD)/tb_sbox.vvp
	$(IVERILOG) -g2005 -I tb/unit -o $(BUILD)/tb_linear.vvp rtl/core/ascon_sbox.v rtl/core/ascon_linear.v tb/unit/tb_linear.v
	$(RUN) $(BUILD)/tb_linear.vvp
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_round.vvp $(RTL_CORE) tb/unit/tb_round.v
	$(RUN) $(BUILD)/tb_round.vvp
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_perm.vvp $(RTL_CORE) tb/unit/tb_perm.v
	$(RUN) $(BUILD)/tb_perm.vvp

# --- Buoc 5b: test vector NIST qua RTL ---
# tb_aead        : ma hoa/giai ma 1089 KAT + test am, truc tiep vao FSM
# tb_apb         : ma hoa 1089 KAT qua bus APB + cac truong hop bien
# tb_apb_session : giai ma 1089 KAT qua APB, test am qua APB, kiem tra
#                  lenh (pslverr), khoa ghi khi busy, SOFT_RESET, ...
# tb_long        : 60 thong diep ngau nhien toi 255 byte (16 khoi) so
#                  voi model (tb/directed/gen_long_vectors.py)
kat:
	@$(MKBUILD)
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_aead.vvp $(RTL_CORE) tb/directed/tb_aead.v
	$(RUN) $(BUILD)/tb_aead.vvp
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_apb.vvp $(RTL_CORE) $(RTL_IP) tb/sva/apb_checker.v tb/directed/tb_apb.v
	$(RUN) $(BUILD)/tb_apb.vvp
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_apb_session.vvp $(RTL_CORE) $(RTL_IP) tb/sva/apb_checker.v tb/directed/tb_apb_session.v
	$(RUN) $(BUILD)/tb_apb_session.vvp
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=$(RPC) -o $(BUILD)/tb_long.vvp $(RTL_CORE) tb/directed/tb_long.v
	$(RUN) $(BUILD)/tb_long.vvp

# --- Buoc 5: cong kiem soat chinh ---
regress: unit kat
	@echo === REGRESSION DONE ===

# regress cho ca ba kien truc
regress_all:
	$(MAKE) regress RPC=1
	$(MAKE) regress RPC=2
	$(MAKE) regress RPC=4

# kat_128_128.hex phai la ban dinh dang lai y nguyen cua file NIST
hexcheck:
	$(PY) tb/directed/gen_kat_hex.py --check

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

# --- Demo board (Genesys 2): mo phong bang Icarus, khong dung Vivado ---
# -DSIM_NO_MMCM: bo qua IBUFDS/MMCME2_BASE (UNISIM, khong co model cho
# Icarus) trong rtl/demo/top_board.v -- xem chu thich dau file do va
# tb/directed/tb_top_board.v.
demo_sim:
	@$(MKBUILD)
	$(IVERILOG) -g2005 -DROUNDS_PER_CYCLE=1 -DSIM_NO_MMCM -o $(BUILD)/tb_top_board.vvp $(RTL_CORE) $(RTL_IP) $(RTL_DEMO) tb/directed/tb_top_board.v
	$(RUN) $(BUILD)/tb_top_board.vvp

# --- Demo board (Genesys 2): tong hop day du + implement + bitstream ---
# (can Vivado that; xem scripts/build_bitstream.tcl)
bitstream:
	vivado -mode batch -source scripts/build_bitstream.tcl

ifeq ($(OS),Windows_NT)
clean:
	@if exist $(BUILD) rmdir /s /q $(BUILD)
	@del /q *.vcd 2>nul
	@del /q vivado*.log vivado*.jou 2>nul
	@if exist .Xil rmdir /s /q .Xil
	@echo Cleaned.
else
clean:
	@rm -rf $(BUILD) .Xil *.vcd vivado*.log vivado*.jou
	@echo Cleaned.
endif
