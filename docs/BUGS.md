# Nhật ký lỗi

## 2026-09-03 — Không chú thích được SDF cho gate-level timing sim (RPC=1, buoc 8)

**Triệu chứng:** `xelab` (bộ mô phỏng `xsim`, Vivado 2022.2) báo lỗi
tắt khi cố nạp SDF sinh bởi `write_sdf` từ `reports/post_route_rpc1.dcp`:
hàng loạt `WARNING: [XSIM 43-3472/43-3467/...] Unable to find delay
expressions for setup/hold/recovery/removal/period/width ... for module
FDCE_default`, rồi `ERROR: [XSIM 43-3462] Unable to annotate SDF delays
in the design.` — xảy ra đồng loạt trên **mọi** thực thể `FDCE` trong
thiết kế, không riêng lẻ một chỗ.

**Cách phát hiện:** Chạy thử `scripts/gatesim.tcl` (mở
`post_route_rpc1.dcp`, `write_verilog -mode timesim -sdf_anno true`,
`write_sdf`, biên dịch/elaborate bằng `xvlog`/`xelab`, chạy `xsim`) sau
khi đã kiểm chứng testbench (`tb/directed/tb_gatesim.v`, 20 vector KAT
chọn lọc) bằng `iverilog` trên RTL — bước rẻ này pass 20/20 nên loại
được khả năng lỗi nằm ở testbench/tập vector trước khi đổ lỗi cho công
cụ. Lần chạy đầu vướng một lỗi path (SDF ghi ở `reports/` nhưng
`$sdf_annotate` sinh ra trong netlist chỉ tham chiếu *basename*, không
kèm thư mục) — sửa bằng cách `cd` vào `reports/` trước khi gọi
`xvlog`/`xelab`; sau khi sửa, lỗi thật ở trên mới lộ ra.

**Nguyên nhân gốc:** Thư viện mô phỏng `unisims_ver` cài kèm bản Vivado
2022.2 tại máy này (không phải thứ tự lệnh Tcl hay RTL) không có
specify-block đầy đủ cho biến thể mặc định của `FDCE` (`FDCE_default`)
— thiếu chính các cặp cổng mà SDF cần khớp (setup/hold giữa `CE`/`D` và
`C`, recovery/removal quanh `CLR`, period/width trên `C`). Hướng khắc
phục đúng là `compile_simlib -simulator xsim -family artix7 -language
verilog -library unisim -dir C:/xsim_libs -force` để dựng lại thư viện
mô phỏng đầy đủ từ nguồn — nhưng thử chạy thì Vivado luôn in
`WARNING: [Vivado 12-5377] Language specific library compilation for
IPs is not supported. By default, the libraries will be compiled for
all languages` (tức annotate lại toàn bộ, không giới hạn được đúng
`-language verilog` như mong muốn cho một thiết kế thuần Verilog không
dùng IP nào), và bản thân bước "Extracting data from the IP repository"
đã mất hơn 1 phút chưa xong — chi phí thời gian không tương xứng với
một bước kiểm chứng phụ trong đồ án này.

**Cách sửa (phương án dự phòng đã dùng):** Bỏ mô phỏng TIMING (SDF),
thay bằng ba phần tách biệt, đều lấy từ chính `post_route_rpc1.dcp`:

1. **Gate-level FUNCTIONAL sim** — `write_verilog -mode funcsim` (không
   `-sdf_anno`, không cần thư viện mô phỏng đặc biệt) xuất netlist
   zero-delay, chạy qua `tb_gatesim.v` (20 vector KAT) bằng `xsim` —
   xác nhận netlist sau đặt chỗ/đi dây đúng chức năng (không xác nhận
   được setup/hold, chỉ đúng logic).
2. **Công suất** — xuất SAIF từ chính lần mô phỏng functional đó (SAIF
   không cần chú thích SDF), nạp bằng `read_saif`, xuất
   `reports/power_rpc1.rpt` qua `report_power`.
3. **Bằng chứng timing** — dùng `report_timing_summary` (phân tích
   tĩnh, không mô phỏng) ngay trên `post_route_rpc1.dcp` đang mở, xuất
   `reports/timing_summary_rpc1.rpt`, thay cho việc quan sát vi phạm
   setup/hold qua mô phỏng có trễ.

Cả ba gộp trong một lần gọi `vivado -mode batch -source
scripts/gatesim.tcl` duy nhất — xem file đó để có chi tiết lệnh.

**Bài học:** Gate-level *timing* simulation (SDF) phụ thuộc vào một thư
viện mô phỏng cài đặt sẵn ngoài tầm kiểm soát của repo — không giống
RTL sim (`iverilog`, tự chứa) hay tổng hợp/STA (`report_timing_summary`,
chỉ cần chính thiết kế + Vivado). Khi một bước kiểm chứng phụ thuộc môi
trường cài đặt cục bộ theo cách không thể sửa bằng RTL/Tcl của dự án,
nên có phương án dự phòng tách timing (đo tĩnh bằng STA, đã có sẵn từ
`sweep_fmax.tcl`/`report_ppa.tcl`) ra khỏi functional/power (đo được
bằng SAIF không cần SDF) thay vì cố ép cả ba vào một luồng mô phỏng có
trễ duy nhất.

---

## 2026-09-02 — Rò bản rõ khối cuối trước khi kiểm tra tag (ascon_aead_fsm)

**Triệu chứng:** Khi giải mã, `dout_valid` bật ngay tại lệnh `PROC_TEXT`
của khối cuối cùng, y hệt các khối trước đó — kể cả khi tag sẽ sai (tag
chỉ được biết sau `FINAL`, xảy ra nhiều lệnh sau đó). Không có cơ chế
nào chặn `DOUT` của khối cuối khi `tag_fail=1`.

**Cách phát hiện:** Viết thêm test âm trong `tb/directed/tb_aead.v`
(lật 1 bit trong ciphertext/tag/AD rồi kiểm `tag_fail` và xác nhận
khối `DOUT` cuối không được xuất ra). Khi soát lại RTL trước khi viết
test, phát hiện `S_XOR_IN` gán `next_dout_valid = 1'b1` vô điều kiện
cho mọi lệnh `PROC_TEXT`, không phân biệt khối cuối lúc giải mã.

**Nguyên nhân gốc:** `docs/uarch.md` (bảng trạng thái FSM, mục 2) mô tả
đúng: giải mã xuất `dout` bằng rate *trước khi* bị ghi đè bởi bản mã,
nhưng không đặc tả rõ việc phải **giữ lại** khối cuối tới khi `FINAL`
xong — đây là yêu cầu ở `docs/spec.md` mục 9.5 ("Hạn chế đã biết — xuất
bản rõ trước khi kiểm tra tag"), không được đưa vào bảng trạng thái khi
viết `ascon_aead_fsm.v` lần đầu.

**Cách sửa:** Thêm thanh ghi `last_pt_r` giữ bản rõ khối cuối tính được
lúc `S_XOR_IN` (giải mã, `last=1`) thay vì xuất ngay. Tại `S_FIN_TAGXOR`,
chỉ gán `dout = last_pt_r`, `dout_valid = 1` nếu `tag_fail` **không**
xảy ra; nếu tag sai thì không bao giờ bật `dout_valid` cho khối đó —
`dout_r` giữ giá trị cũ, không lộ ra ngoài qua giao diện chính thức.

**Bài học:** Khi vi kiến trúc hóa một yêu cầu bảo mật/an toàn nêu ở
`docs/spec.md`, phải đưa yêu cầu đó thành một dòng rõ ràng trong bảng
trạng thái FSM (`docs/uarch.md`) trước khi viết RTL — không thể trông
chờ đọc lại đặc tả khi coding sẽ tự nhớ ra. Test âm (cố tình phá dữ
liệu để xác nhận cơ chế an toàn kích hoạt) cần được viết chủ động, vì
test dương (KAT hợp lệ) không bao giờ chạm tới nhánh `tag_fail=1`.

---

## 2026-09-02 — Chuỗi CARRY4 ngoài ý muốn trên dout_r (ascon_aead_fsm)

**Triệu chứng:** Báo cáo timing (`reports/timing_critical.rpt`, một
lần chạy `sweep_fmax.tcl` trước đó ở period=6.000 ns) cho thấy đường
tới hạn thứ hai đi qua 10 khối `CARRY4` nối tiếp
(`u_fsm/u_perm/dout_r_reg[127]_i_*`), tạo chuỗi carry ~40 bit feed vào
`dout_r`. Ascon không có phép toán số học nào — đây là mạch phát sinh
ngoài ý muốn từ logic đệm byte theo `valid_bytes` trong
`f_enc_rate`/`f_dec_rate` (khi đó viết bằng vòng `for` so sánh
`k == vbytes` / `k > vbytes` / `k < vbytes`).

**Cách phát hiện:** Đọc lại `reports/timing_critical.rpt` đã có sẵn từ
lần chạy `make impl` trước đó (không phải tạo mới trong phiên này).

**Đã thử và kết quả — bằng `make synth` thật (Vivado 2022.2 có sẵn tại
`C:\Xilinx\Vivado\2022.2`), không chỉ suy luận:**

| Cách thử | Slice LUTs | CARRY4 | Kết quả |
|---|---|---|---|
| Gốc (vòng `for` so sánh `k <op> vbytes`) | 1824 | 11 | baseline |
| `case` xây mảng mặt nạ (bit i = i<vbytes) rồi AND/OR với dữ liệu | 1702 | 11 | LUT giảm, CARRY4 không đổi |
| `case` 17 nhánh viết thẳng kết quả 128 bit bằng dải bit hằng số (không còn mặt nạ trung gian, không còn toán tử `<`/`>` nào trong file) | 1566 | 11 | LUT giảm tiếp, CARRY4 **vẫn không đổi** |
| Thêm `(* use_carry = "no" *)` trên `dout_r`, `next_dout`, `rate_new`, `perm_state_i`, thanh ghi `state` trong `ascon_perm` | 1566 | 11 | Không đổi gì |
| Thêm cả `(* dont_touch = "true" *)` trên `rate_new` | 1566 | 11 | Không đổi gì |
| `synth_design ... -resource_sharing off` | 1566 | 11 | Không đổi gì |
| `(* use_carry = "no" *)` đặt ở mức module | 1566 | 11 | Không đổi gì |

**Phát hiện bằng cách chia đôi (bisect) trên bản sao file:** xóa hẳn
phép so sánh `next_tag != tag_in` (128 bit, ở `S_FIN_TAGXOR`, dùng để
tính `tag_fail`) — dù **không đụng gì tới** `f_enc_rate`/`f_dec_rate`
— thì chuỗi CARRY4 trên `dout_r` **biến mất hoàn toàn** (0 CARRY4).
Phục hồi lại phép so sánh thì chuỗi quay lại y hệt, dù đã gắn
`use_carry=no` riêng cho `tag_r`/`next_tag`/`tag_fail_r`/`next_tag_fail`.
Test cô lập (module tối giản, không có `ascon_apb`/`ascon_perm`) xác
nhận `case` 17-nhánh + `use_carry=no` hoạt động đúng như kỳ vọng khi
đứng một mình (0 CARRY4) — vấn đề chỉ xuất hiện khi phép so sánh tag
128 bit cùng tồn tại trong cùng module.

**Kết luận:** Nguyên nhân gốc chưa được giải quyết triệt để. Việc viết
lại bằng `case`/bảng tra là đúng hướng và có lợi thật (giảm LUT
1824→1566, tương đương 14%, code cũng rõ ràng/dễ kiểm hơn hẳn), nhưng
tự nó **không đủ** để loại chuỗi CARRY4 — Vivado 2022.2 rõ ràng đang
chia sẻ hạ tầng carry-chain giữa phép so sánh tag hợp lệ (128 bit,
không tránh được) và mux đệm byte của `dout_r`, theo cách không điều
khiển được bằng các đòn bẩy RTL/synth thông thường đã thử ở trên.
Không giữ lại các thuộc tính `use_carry`/`dont_touch` trong RTL vì đã
xác nhận chúng không có tác dụng — giữ lại code "trông như đã sửa"
nhưng thực ra vô hiệu còn tệ hơn không viết gì.

**Việc còn để lại:** Kiểm `reports/timing_critical.rpt`/chạy lại
`sweep_fmax.tcl` để xem chuỗi CARRY4 hiện tại có thực sự vi phạm timing
ở tần số mục tiêu hay không (báo cáo cũ cho thấy path này **vẫn đạt**
slack dương ở period=6 ns) trước khi đầu tư thêm công sức; nếu cần xử
lý tiếp, hướng khả thi nhất là tách vật lý phép so sánh tag ra một
module/instance riêng (không cùng always-block hay file) để phá vỡ cơ
hội chia sẻ tài nguyên của Vivado, hoặc hỏi hỗ trợ Xilinx.

**Bài học:** Với Vivado Synth_8, viết lại RTL bằng `case` thay vì toán
tử so sánh **không đảm bảo** đổi được lựa chọn công nghệ ánh xạ, vì
công cụ chuẩn hóa RTL về mạng Boolean trước khi tối ưu — hai cách viết
tính ra cùng một hàm thì thường ra cùng một mạch, bất kể cú pháp
nguồn. Luôn đo bằng `report_utilization`/tên cell CARRY4 thật sau mỗi
lần sửa, đừng suy luận rồi báo cáo cải thiện dựa trên "về lý thuyết
phải đúng".
