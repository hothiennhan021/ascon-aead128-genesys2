# Rang buoc Out-of-Context cho rtl/ip/ascon_apb.v (top = ascon_apb)
# Chi dinh chu ky dong ho cho pclk - buoc 6 trong quy trinh lam viec,
# xem docs/uarch.md va CLAUDE.md.

create_clock -period 10.000 -name pclk [get_ports pclk]
