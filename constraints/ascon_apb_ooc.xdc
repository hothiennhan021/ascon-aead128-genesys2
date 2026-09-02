# Rang buoc Out-of-Context cho rtl/ip/ascon_apb.v (top = ascon_apb)
# Chi dinh chu ky dong ho cho pclk - buoc 6 trong quy trinh lam viec,
# xem docs/uarch.md va CLAUDE.md.

create_clock -period 10.000 -name pclk [get_ports pclk]

# Chi dinh nguon dong ho gia dinh cho pclk trong boi canh Out-of-
# Context: khi tich hop that, pclk se duoc cap tu mot BUFG. Neu khong
# khai bao, cong cu implement khong biet loai driver nao se lai vao
# cong nay, phat sinh canh bao Timing 38-242 ("clock port has no
# driver / ambiguous clock source") trong che do OOC.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports pclk]
