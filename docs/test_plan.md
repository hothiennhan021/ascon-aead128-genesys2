# Kế hoạch kiểm chứng

Bảng này nối từng yêu cầu trong `docs/spec.md` với testbench kiểm nó.
Mọi testbench tự in `PASS`/`FAIL`; `scripts/run_sim.py` biến dòng `FAIL`
thành mã lỗi nên `make regress` dừng ngay khi có test hỏng.

## Cách chạy

```
make model        # model Python: 1089 KAT mã hóa + giải mã + từ chối tag sai
make hexcheck     # tb/directed/kat_128_128.hex khớp y nguyên file NIST
make regress      # unit + KAT + APB + phiên APB + thông điệp dài (RPC mặc định 1)
make regress_all  # regress cho RPC = 1, 2, 4
make demo_sim     # demo UART trên Genesys 2 (mô phỏng)
```

CI (`.github/workflows/regress.yml`) chạy `model`, `hexcheck`, `regress`
cho cả ba giá trị RPC và `demo_sim` ở mỗi lần push / pull request.

## Testbench

| Testbench | Mức | Kiểm gì |
|---|---|---|
| `tb/unit/tb_sbox.v`, `tb_linear.v`, `tb_round.v` | module | S-box, lớp tuyến tính, một vòng — so với dump từng vòng của model (p12, p8 từ trạng thái 0) |
| `tb/unit/tb_perm.v` | module | `ascon_perm` với `ROUNDS_PER_CYCLE` = 1/2/4, cờ `busy`/`done` |
| `tb/directed/tb_aead.v` | FSM | 1089 KAT mã hóa + giải mã; test âm lật 1 bit CT/tag/AD; `mode_lock` |
| `tb/directed/tb_long.v` | FSM | 60 thông điệp ngẫu nhiên AD/PT tới 255 byte (16 khối), mã hóa + giải mã, so với model |
| `tb/directed/tb_apb.v` | APB | 1089 KAT mã hóa qua bus; KEY đọc 0; thiếu DIN; địa chỉ lạ/lệch; reset giữa chừng; lệnh khi busy; ghi thừa DIN; hai phiên liền nhau |
| `tb/directed/tb_apb_session.v` | APB | 1089 KAT giải mã qua bus; test âm qua bus; `tag_fail` xóa ở phiên sau; mặt nạ DIN; kiểm tra lệnh (19 trường hợp); khóa ghi khi busy; che byte thừa DOUT; `SOFT_RESET`; nạp trước DIN khi busy |
| `tb/directed/tb_top_board.v` | hệ thống | UART → `cmd_fsm` → `apb_master` → `ascon_apb`, 2 vector KAT |
| `tb/directed/tb_gatesim.v` | netlist | 20 vector KAT trên netlist sau route (Vivado xsim), cũng chạy được trên RTL |
| `tb/sva/apb_checker.v` | giám sát | Luật 1–3: master APB; luật 4–8: slave (`tag_fail` ⇒ không `dout_valid`, KEY đọc 0, `pslverr` chỉ trong ACCESS, `prdata`/`pready` không X) |

## Truy vết yêu cầu → test

| Yêu cầu (`docs/spec.md`) | Test |
|---|---|
| Đúng Ascon-AEAD128 (mục 2, 3) | `make model`, `tb_aead`, `tb_apb`, `tb_apb_session` (1089 KAT), `tb_long` |
| KEY chỉ ghi (9.1) | `tb_apb` `key_read_zero`, `apb_checker` luật 5 |
| `din_full` theo 4 từ (9.3) | `tb_apb` `din_underflow_rejected`, `din_overwrite_deterministic`; `tb_apb_session` `din_mask` |
| `valid_bytes`, khối đệm (9.4) | KAT mọi độ dài 0–32; `tb_long`; `tb_apb_session` `cmd_checks` |
| Giữ khối cuối, không lộ tag khi giải mã (9.5) | `tb_aead` test âm + `mode_lock`; `tb_apb_session` `decrypt_kat`, `decrypt_neg`, `tag_fail_clear`; `apb_checker` luật 4 |
| Kiểm tra lệnh, thứ tự phiên (9.6) | `tb_apb_session` `cmd_checks` |
| Ghi khi busy (7, 7.1) | `tb_apb` `busy_write_ignored`; `tb_apb_session` `busy_write_lock`, `din_prewrite` |
| Byte thừa DOUT đọc 0 (7) | `tb_apb_session` `dout_mask`, `decrypt_kat`; `tb_long` |
| `SOFT_RESET` (7.1) | `tb_apb_session` `soft_reset` |
| Giao thức APB (6.2) | `apb_checker` trong `tb_apb`, `tb_apb_session` |
| Netlist sau route đúng chức năng (11) | `make gatesim` (Vivado) |

## Chưa phủ

- Mô phỏng gate-level có trễ (SDF) — xem `docs/BUGS.md` 2026-09-03.
- Chạy trên board thật (Genesys 2).
- Sau thay đổi RTL bản 0.2, cần chạy lại `make synth impl report gatesim`
  để cập nhật PPA và netlist.
