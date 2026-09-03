# Constraints cho rtl/demo/top_board.v tren Genesys 2 (xc7k325tffg900-2).
# Chi giu lai cac chan top_board.v thuc su dung: clock vi sai he thong,
# UART, 8 LED, nut BTNC. Toa do chan/IOSTANDARD doi chieu tu file mau
# chinh thuc cua Digilent (Genesys-2-Master.xdc, kho digilent-xdc tren
# Github) -- KHONG tu doan; cac chan khac trong file mau (HDMI, SD,
# SFP, DDR3, Ethernet, cac nut/switch con lai, v.v.) bi bo qua vi
# top_board.v khong dung den.

## System clock -- vi sai 200 MHz (khong phai clock don), xem
## rtl/demo/top_board.v muc chu thich dau file ve IBUFDS + MMCME2_BASE.
set_property -dict { PACKAGE_PIN AD12  IOSTANDARD LVDS } [get_ports { sysclk_p }]; #IO_L12P_T1_MRCC_33 Sch=sysclk_p
set_property -dict { PACKAGE_PIN AD11  IOSTANDARD LVDS } [get_ports { sysclk_n }]; #IO_L12N_T1_MRCC_33 Sch=sysclk_n
create_clock -period 5.000 -name sysclk_p [get_ports { sysclk_p }]

## UART (qua cau USB-UART tren board) -- ten chan giu nguyen theo goc
## nhin cua chip cau USB-UART: uart_rx_out la NGO RA cua chip cau noi
## VAO chan RX cua FPGA (input tren top_board.v), uart_tx_in la NGO
## VAO cua chip cau noi tu chan TX cua FPGA (output tren top_board.v).
set_property -dict { PACKAGE_PIN Y23   IOSTANDARD LVCMOS33 } [get_ports { uart_rx_out }]; #IO_L1P_T0_12 Sch=uart_rx_out
set_property -dict { PACKAGE_PIN Y20   IOSTANDARD LVCMOS33 } [get_ports { uart_tx_in }];  #IO_0_12 Sch=uart_tx_in

## Nut BTNC -- dung lam reset he thong. Y HD: bank IO cua nut nay dung
## LVCMOS12, KHAC voi LED/UART (LVCMOS33) -- giu dung nhu file mau,
## sai IOSTANDARD o day se khong bao loi DRC ro rang nhung doc muc
## logic sai.
set_property -dict { PACKAGE_PIN E18   IOSTANDARD LVCMOS12 } [get_ports { btnc }]; #IO_25_17 Sch=btnc

## LED0..LED7 -- LED0=busy, LED1=done, LED7=tag_fail (con lai khong
## dung, top_board.v da noi cung 0), xem rtl/demo/top_board.v.
set_property -dict { PACKAGE_PIN T28   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #IO_L11P_T1_SRCC_31 Sch=led[0]
set_property -dict { PACKAGE_PIN V19   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_L23N_T3_31 Sch=led[1]
set_property -dict { PACKAGE_PIN U30   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #IO_L4N_T0_31 Sch=led[2]
set_property -dict { PACKAGE_PIN U29   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]; #IO_L4P_T0_31 Sch=led[3]
set_property -dict { PACKAGE_PIN V20   IOSTANDARD LVCMOS33 } [get_ports { led[4] }]; #IO_L21P_T3_DQS_31 Sch=led[4]
set_property -dict { PACKAGE_PIN V26   IOSTANDARD LVCMOS33 } [get_ports { led[5] }]; #IO_L20N_T3_31 Sch=led[5]
set_property -dict { PACKAGE_PIN W24   IOSTANDARD LVCMOS33 } [get_ports { led[6] }]; #IO_L6P_T0_31 Sch=led[6]
set_property -dict { PACKAGE_PIN W23   IOSTANDARD LVCMOS33 } [get_ports { led[7] }]; #IO_L6N_T0_VREF_31 Sch=led[7]

## Cau hinh bank/config chuan cho 7-series -- dung trong hau het file
## mau Digilent de tranh DRC lien quan dien ap cau hinh.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
