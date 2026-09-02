# Nhật ký lỗi

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
