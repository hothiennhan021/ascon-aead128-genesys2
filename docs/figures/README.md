# Danh sách hình cho báo cáo

Tất cả hình xuất PNG 300 DPI, nền trắng, chữ tiếng Việt (font DejaVu
Sans, cỡ chữ tối thiểu tương đương 11pt khi in). Script sinh hình nằm
cùng thư mục (`_gen_charts.py` cho nhóm biểu đồ số liệu,
`_gen_diagrams.py` cho nhóm sơ đồ) — chạy lại bằng `python
docs/figures/_gen_charts.py` / `_gen_diagrams.py` nếu số liệu trong
`reports/` hoặc `docs/comparison.md` thay đổi.

**Ghi chú kỹ thuật:** nhóm sơ đồ (block/datapath/FSM/phases) được vẽ
trực tiếp bằng `matplotlib` (hộp bo góc `FancyBboxPatch` + mũi tên
`FancyArrowPatch`) thay vì quy trình SVG → PNG bằng `cairosvg`/Inkscape
như dự kiến ban đầu, vì máy build không có thư viện `cairo` gốc lẫn
Inkscape cài sẵn. Kết quả hình ảnh tương đương về phong cách (nền
trắng, hộp chữ nhật bo góc, mũi tên có nhãn, không đổ bóng) và dùng
chung font với nhóm biểu đồ số liệu.

---

## Nhóm 1 — biểu đồ từ số liệu

### `pareto_area_throughput.png`
Thông lượng tiệm cận (Mbps) so với LUT tổng, ba điểm
`ROUNDS_PER_CYCLE` ∈ {1, 2, 4} (nguồn `reports/ppa.csv`). Đường nét
đứt nối RPC=1 và RPC=2 — biên Pareto thật sự, vì RPC=4 bị RPC=2 lấn át
hoàn toàn (thông lượng thấp hơn **và** LUT cao hơn).

**Chú thích đề xuất:** *Hình X. Diện tích so với thông lượng tiệm cận
của ba cấu hình ROUNDS_PER_CYCLE. RPC=2 nằm trên biên Pareto cùng
RPC=1; RPC=4 bị lấn át hoàn toàn — không phải điểm tối ưu dù xử lý
song song nhiều vòng hoán vị hơn.*

### `efficiency_vs_unroll.png`
Biểu đồ cột hiệu suất diện tích (Mbps/LUT) theo `ROUNDS_PER_CYCLE` ∈
{1, 2, 4}, cột RPC=2 tô màu khác và ghi chú "tối ưu" — đạt 1.890
Mbps/LUT, cao nhất trong ba điểm đo, rồi **đảo chiều giảm** ở RPC=4
(1.074, thấp hơn cả RPC=1).

**Chú thích đề xuất:** *Hình X. Hiệu suất diện tích (Mbps/LUT) đạt
đỉnh tại ROUNDS_PER_CYCLE=2 rồi giảm mạnh ở RPC=4 — không phải hiện
tượng bão hòa mà là đảo chiều thật sự (xem docs/uarch.md mục 7.2).*

### `multidevice_fmax.png`
Biểu đồ cột Fmax (MHz) trên ba dòng FPGA Xilinx 7-series
(`ROUNDS_PER_CYCLE=1`), ghi rõ speed grade dưới mỗi cột (nguồn
`reports/ppa_multidevice.csv`). Artix-7 đo ở speed grade **-1** (mức
chậm nhất, xem `docs/spec.md` mục 5); Kintex-7 và Virtex-7 đo ở -2.

**Chú thích đề xuất:** *Hình X. Fmax trên ba dòng FPGA Xilinx 7-series
cùng RTL, cùng ràng buộc. Artix-7 đo ở speed grade -1 (bảo thủ nhất
trong họ); Kintex-7 và Virtex-7 đo ở -2.*

### `comparison_area_throughput.png`
Biểu đồ phân tán so sánh diện tích (LUT) – thông lượng (Mbps) trên
Artix-7 giữa đồ án này và ba công trình liên quan trong
`docs/comparison.md` mục 2 (Alharbi 2024; Malal — ASCON-128; Malal —
ASCON-128a), mỗi điểm một nhãn.

**Chú thích đề xuất:** *Hình X. So sánh diện tích–thông lượng trên
Artix-7 với ba công trình liên quan. Lưu ý: ba công trình đối chiếu
hiện thực Ascon-128 bản v1.2 (rate 64/128 bit tùy biến thể), không
phải Ascon-AEAD128 theo NIST SP 800-232 — số liệu chỉ mang tính định
vị tương đối, không so sánh ngang hàng tuyệt đối (xem lưu ý đầy đủ ở
`docs/comparison.md` mục 1).*

---

## Nhóm 2 — sơ đồ khối

### `block_diagram.png`
Sơ đồ khối hệ thống: vi xử lý (CPU/SoC) kết nối qua bus AMBA APB tới
lõi IP Ascon-AEAD128, bên trong gồm ba khối theo đúng thứ tự phân
cấp: APB slave (`rtl/ip/ascon_apb.v`) → `ascon_aead_fsm` (điều khiển
AEAD) → `ascon_perm` (hoán vị p12/p8).

**Chú thích đề xuất:** *Hình X. Sơ đồ khối tích hợp lõi IP
Ascon-AEAD128 vào hệ thống qua giao diện AMBA APB slave.*

### `datapath.png`
Datapath kiến trúc một vòng hoán vị mỗi chu kỳ (`ROUNDS_PER_CYCLE=1`):
thanh ghi trạng thái 320 bit ở trung tâm, khối `ascon_round` tổ hợp
thuần túy, bộ đếm vòng `round_idx` tra bảng hằng số RC bằng `case`,
đường phản hồi từ thanh ghi trạng thái về lại khối hoán vị, đường XOR
dữ liệu vào rate (`din[127:0]` → S0/S1, kèm bit phân tách miền), và
đường xuất bản mã/bản rõ `dout[127:0]`. Bám theo sơ đồ ASCII trong
`docs/uarch.md` mục 1.

**Chú thích đề xuất:** *Hình X. Datapath kiến trúc một vòng hoán vị
mỗi chu kỳ (ROUNDS_PER_CYCLE=1). Thanh ghi trạng thái 320 bit là điểm
neo duy nhất; mọi khối tổ hợp phía trên chỉ tính giá trị kế tiếp.*

### `fsm_diagram.png`
Máy trạng thái AEAD (`ascon_aead_fsm`) với 7 trạng thái theo bảng mục
2 của `docs/uarch.md`: `S_IDLE`, `S_LOAD`, `S_XOR_IN`, `S_PERM`,
`S_INIT_KEYXOR`, `S_FIN_KEYXOR`, `S_FIN_TAGXOR`. Ba cạnh quay về
`S_IDLE` (từ `S_PERM`, `S_INIT_KEYXOR`, `S_FIN_TAGXOR`) được định
tuyến vòng theo hành lang ngoài bên trái/phải để không cắt qua các
trạng thái khác.

**Chú thích đề xuất:** *Hình X. Máy trạng thái điều khiển AEAD.
Trạng thái S_PERM dùng chung cho cả p8 lẫn p12, khác nhau ở giá trị
nạp round_idx (4 cho p12, 8 cho p8) và ret_state quay về sau khi
hoán vị xong.*

### `aead_phases.png`
Bốn giai đoạn của Ascon-AEAD128 theo trình tự xử lý: Khởi tạo (p12) →
Xử lý AD (p8 mỗi khối) → Xử lý bản rõ (p8 mỗi khối trừ khối cuối) →
Hoàn tất (p12), kèm đầu vào K/N (khởi tạo), A (AD), P (bản rõ) và đầu
ra C (bản mã), T (tag).

**Chú thích đề xuất:** *Hình X. Bốn giai đoạn xử lý của
Ascon-AEAD128: khởi tạo và hoàn tất dùng p12, xử lý AD/bản rõ dùng p8
mỗi khối (khối bản rõ cuối cùng không chạy p8 — xem mục "những chỗ
hay sai" #4 trong CLAUDE.md).*
