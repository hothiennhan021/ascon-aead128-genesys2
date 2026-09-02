# Makefile cho do an ASCON-AEAD128 - phien ban Windows
# Yeu cau: python, iverilog, vvp, make trong PATH
# LUU Y: cac dong lenh phai bat dau bang ky tu TAB, khong phai dau cach

PY       := python
IVERILOG := iverilog
VVP      := vvp

# TODO: them lai rtl/core/ascon_aead_fsm.v khi module do duoc viet
RTL_CORE := rtl/core/ascon_sbox.v rtl/core/ascon_linear.v \
            rtl/core/ascon_round.v rtl/core/ascon_perm.v
RTL_IP   := rtl/ip/ascon_apb.v
BUILD    := build
KAT      := vectors/LWC_AEAD_KAT_128_128.txt

.PHONY: all model unit kat regress synth impl power clean help

help:
	@echo.
	@echo   make model     - chay mo hinh Python voi test vector NIST
	@echo   make unit      - test tung module RTL
	@echo   make kat       - chay test vector qua RTL
	@echo   make regress   - chay toan bo testbench
	@echo   make synth     - tong hop Out-of-Context bang Vivado
	@echo   make impl      - implement va quet Fmax
	@echo   make power     - do cong suat bang SAIF
	@echo   make clean     - xoa file tam
	@echo.

all: model regress

# --- Buoc 2: mo hinh tham chieu ---
model:
	$(PY) model/ascon_model.py --run-kat $(KAT)

# --- Buoc 5a: test tung module ---
unit:
	@if not exist $(BUILD) mkdir $(BUILD)
	$(IVERILOG) -g2005 -I tb/unit -o $(BUILD)/tb_sbox.vvp rtl/core/ascon_sbox.v rtl/core/ascon_linear.v tb/unit/tb_sbox.v
	$(VVP) $(BUILD)/tb_sbox.vvp
	$(IVERILOG) -g2005 -I tb/unit -o $(BUILD)/tb_linear.vvp rtl/core/ascon_sbox.v rtl/core/ascon_linear.v tb/unit/tb_linear.v
	$(VVP) $(BUILD)/tb_linear.vvp
	$(IVERILOG) -g2005 -o $(BUILD)/tb_round.vvp $(RTL_CORE) tb/unit/tb_round.v
	$(VVP) $(BUILD)/tb_round.vvp
	$(IVERILOG) -g2005 -o $(BUILD)/tb_perm.vvp $(RTL_CORE) tb/unit/tb_perm.v
	$(VVP) $(BUILD)/tb_perm.vvp

# --- Buoc 5b: test vector NIST qua RTL ---
kat:
	@if not exist $(BUILD) mkdir $(BUILD)
	$(IVERILOG) -g2005 -o $(BUILD)/tb_aead.vvp $(RTL_CORE) tb/directed/tb_aead.v
	$(VVP) $(BUILD)/tb_aead.vvp

# --- Buoc 5: cong kiem soat chinh ---
regress: unit kat
	@echo === REGRESSION DONE ===

# --- Buoc 6: tong hop Out-of-Context ---
synth:
	vivado -mode batch -source scripts/synth_ooc.tcl

# --- Buoc 7: implement va quet Fmax ---
impl:
	vivado -mode batch -source scripts/sweep_fmax.tcl

# --- Buoc 8: do cong suat ---
power:
	vivado -mode batch -source scripts/report_power.tcl

clean:
	@if exist $(BUILD) rmdir /s /q $(BUILD)
	@del /q *.vcd 2>nul
	@del /q vivado*.log vivado*.jou 2>nul
	@if exist .Xil rmdir /s /q .Xil
	@echo Cleaned.
