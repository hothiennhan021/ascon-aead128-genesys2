# So sánh PPA với công trình liên quan

| | |
|---|---|
| **Ngày** | 2026-09-03 |
| **Tác giả** | Hồ Thiện Nhân — MSSV 23521073 |
| **Nguồn số liệu của đồ án** | `reports/ppa_multidevice.csv`, `reports/ppa.csv`, `reports/power_rpc1.rpt` |

---

## 1. Lưu ý bắt buộc đọc trước khi dùng bảng

**Cả ba công trình đối chiếu bên dưới hiện thực Ascon-128 bản đệ trình v1.2** (rate 64
bit, hoán vị trung gian p6, biểu diễn big-endian) — **không phải Ascon-AEAD128 theo
NIST SP 800-232** (rate 128 bit, hoán vị trung gian p8, little-endian) như đồ án này.
Hai biến thể có tốc độ dòng dữ liệu lý thuyết khác nhau ngay từ định nghĩa (rate 64 so
với 128 bit mỗi khối), nên các con số throughput và Mbps/LUT **không so sánh ngang
hàng tuyệt đối** — bảng dưới đây phục vụ mục đích định vị tương đối trong họ Ascon,
không phải để tuyên bố hơn/kém trực tiếp.

Riêng biến thể **ASCON-128a** trong bài của Malal dùng rate 128 bit — cùng kích thước
khối với Ascon-AEAD128 của đồ án — nên là điểm đối chiếu gần nhất về mặt cấu trúc dữ
liệu, dù hoán vị trung gian của ASCON-128a vẫn là p8 với IV và call sequence theo v1.2,
khác XOR khóa và IV theo SP 800-232.

**Speed grade:** Thiết kế này báo cáo trên `xc7a35tcpg236-1` speed grade **−1**, chậm
nhất trong họ Artix-7 (còn có −2, −3). Alharbi và Malal đều dùng linh kiện speed grade
−2 hoặc −3 nhanh hơn. Do đó **Fmax 182 MHz trên Artix-7 của đồ án này là con số bảo
thủ** — cùng RTL trên speed grade −2/−3 sẽ cho Fmax cao hơn. Trên Kintex-7 và Virtex-7,
đồ án này đã dùng speed grade −2, cùng cấp hoặc gần cấp với các công trình đối chiếu.

Cột throughput của đồ án lấy từ `throughput_asymptotic_Mbps` trong
`reports/ppa_multidevice.csv` — tức thông lượng ổn định (rate/cycles_per_block ở pha
xử lý khối, không tính chi phí một-lần của khởi tạo/hoàn tất) — cùng cách tính mà Malal
dùng. Alharbi tính throughput trên tổng số chu kỳ của toàn bộ phép AEAD (gồm cả
khởi tạo và hoàn tất), nên throughput của Alharbi thấp hơn tương đối so với cách tính
asymptotic ở cùng Fmax. Công suất của đồ án chỉ đo được ở cấu hình RPC=1 trên
Artix-7 (gate-level, có SAIF) — chưa có số đo công suất trên Kintex-7/Virtex-7.

---

## 2. Bảng so sánh trên Artix-7

| Công trình | Biến thể Ascon | FPGA | Speed grade | LUT | Fmax (MHz) | Throughput (Mbps) | Mbps/LUT | Công suất (mW) |
|---|---|---|---|---:|---:|---:|---:|---:|
| **Đồ án này** | Ascon-AEAD128 (SP 800-232, rate 128, p8) | xc7a35tcpg236-1 | **−1** | 1555 | 182.25 | 2592.00 | 1.667 | 91 (tổng on-chip) / 23 (động) |
| Alharbi 2024 [1] | Ascon-128 v1.2 (rate 64, p6) | xc7a100tcsg324-3 | −3 | 1756 | 317 | 376 | 0.214 | 222 |
| Malal (n.d.) [2] | ASCON-128 v1.2 (rate 64, p6) | xc7a200tfbg676-2 | −2 | 2957 | 55.25 | 3535.91 | 1.19 | — |
| Malal (n.d.) [2] | ASCON-128a v1.2 (rate 128, p8) | xc7a200tfbg676-2 | −2 | 2183 | 83.33 | 5333.30 | 2.44 | — |

Ghi chú:
- Đồ án đạt Mbps/LUT cao hơn Alharbi dù dùng speed grade chậm nhất, chủ yếu vì rate
  128 bit của Ascon-AEAD128 cho throughput/khối gấp đôi Ascon-128 v1.2 ở cùng số chu
  kỳ hoán vị p8 so với p6.
- Hai dòng của Malal xử lý nhiều vòng hoán vị song song trong một chu kỳ (6 round/chu
  kỳ cho ASCON-128, 4 round/chu kỳ cho ASCON-128a) nên Fmax thấp nhưng throughput
  rất cao — đây là kiến trúc round-parallel, khác hẳn kiến trúc 1 round/chu kỳ (iterative)
  của đồ án này và của Alharbi. So Mbps/LUT giữa hai lớp kiến trúc khác nhau này chỉ
  mang tính tham khảo.
- Malal không báo cáo công suất.

---

## 3. Bảng so sánh trên Kintex-7 và Virtex-7

| Công trình | Biến thể Ascon | FPGA | Speed grade | LUT | Fmax (MHz) | Throughput (Mbps) | Mbps/LUT | Công suất (mW) |
|---|---|---|---|---:|---:|---:|---:|---:|
| **Đồ án này** | Ascon-AEAD128 (SP 800-232, rate 128, p8) | xc7k325tffg900-2 | −2 | 1557 | 304.04 | 4324.12 | 2.777 | — |
| Alharbi 2024 [1] | Ascon-128 v1.2 (rate 64, p6) | xc7k480tffg1156-3 | −3 | 1497 | 331 | 400 | 0.267 | 236 |
| Malal (n.d.) [2] | ASCON-128 v1.2 (rate 64, p6) | xc7k160tfbg676-3 | −3 | 2958 | 92.59 | 5925.92 | 2.01 | — |
| Malal (n.d.) [2] | ASCON-128a v1.2 (rate 128, p8) | xc7k160tfbg676-3 | −3 | 3051 | 158.73 | 10158.00 | 3.32 | — |
| **Đồ án này** | Ascon-AEAD128 (SP 800-232, rate 128, p8) | xc7vx485tffg1761-2 | −2 | 1558 | 273.45 | 3889.07 | 2.496 | — |
| Alharbi 2024 [1] | Ascon-128 v1.2 (rate 64, p6) | xc7vx690tffg1930-3 | −3 | 1632 | 335 | 400 | 0.245 | 239 |

Ghi chú:
- Malal không có dữ liệu Virtex-7 trong bài báo (chỉ Artix-7, Kintex-7, Spartan-7/6).
- Trên Kintex-7 và Virtex-7, đồ án dùng speed grade −2 trong khi Alharbi và Malal dùng
  −3 (nhanh hơn một cấp); dù vậy Fmax của đồ án vẫn thấp hơn vì kiến trúc hoán vị của
  đồ án gồm datapath 320-bit tổ hợp toàn phần một round mỗi chu kỳ chưa được tối ưu
  pipeline sâu như các công trình đối chiếu.
- Đồ án chưa đo công suất trên Kintex-7/Virtex-7 (chỉ có báo cáo gate-level power cho
  cấu hình RPC=1 trên Artix-7, xem `reports/power_rpc1.rpt`).

---

## 4. Mốc tham khảo diện tích cực tiểu — Mohamed và cộng sự (Lattice iCE40)

Bài Mohamed và cộng sự [3] hiện thực Ascon-128 v1.2 bằng kiến trúc **serial hóa** (xử
lý S-box 5-bit tuần tự, không song song 64 lần) trên FPGA họ Lattice iCE40 — khác kiến
trúc và khác họ linh kiện hoàn toàn so với dòng Xilinx 7-series, nên đặt riêng làm mốc
tham khảo cận dưới về diện tích, không đưa vào bảng so sánh Artix/Kintex/Virtex ở
trên.

| Công trình | Biến thể Ascon | FPGA | LUT | FF | Fmax (MHz) | Throughput (Mbps) | Công suất (mW) |
|---|---|---|---|---:|---:|---:|---:|
| Mohamed và cộng sự 2026 [3] | Ascon-128 v1.2 (rate 64, p6), serial hóa | Lattice iCE40 (ICE40HX1K-STICK-EVN) | 582 | 418 | 228.8 (đo Fmax) / hoạt động thực tế 13.7 hoặc 200 | 0.326 (@13.7 MHz) / 4.761 (@200 MHz) | 2.27 (@13.7 MHz) / 27.74 (@200 MHz) |
| **Đồ án này** (để đối chiếu quy mô) | Ascon-AEAD128 (SP 800-232) | xc7a35tcpg236-1 (Artix-7, −1) | 1555 | 1517 | 182.25 | 2592.00 | 91 (tổng on-chip) |

Nhận xét:
- Diện tích 582 LUT của Mohamed thấp hơn ~2.7× so với 1555 LUT của đồ án này — cái
  giá đánh đổi là throughput thấp hơn ~8–16× tùy tần số hoạt động, do kiến trúc serial
  xử lý S-box từng lát 5-bit thay vì toàn bộ 64 lát song song mỗi chu kỳ (đồ án này xử lý
  cả 320-bit trạng thái mỗi chu kỳ, tức "iterative" chứ không "serial hóa").
  Nói cách khác, hai thiết kế nằm ở hai đầu cực khác nhau của trục diện tích–thông
  lượng: Mohamed tối ưu diện tích/công suất cực tiểu (RFID passive tag), đồ án này nhắm
  cân bằng thông lượng/diện tích cho ứng dụng AMBA-APB SoC.
- Số FF của Mohamed (418) thấp hơn nhiều so với đồ án (1517) vì trạng thái 320-bit của
  Mohamed dùng thanh ghi dịch (shift register) tái sử dụng cho cả nạp dữ liệu, S-box và
  khuếch tán, trong khi đồ án dùng thanh ghi song song đầy đủ cho giao diện APB.
- Bài Mohamed cũng báo cáo kết quả ASIC 16nm TSMC FinFET (1.341 kGE, 0.254 mW,
  100 MHz) — không đối chiếu ở đây vì đồ án chỉ có kết quả FPGA.

---

## 5. Tóm tắt diễn giải

1. **Ascon-AEAD128 (đồ án) vs Ascon-128 v1.2 (Alharbi):** cùng kiến trúc iterative
   1 round/chu kỳ, đồ án đạt Mbps/LUT cao hơn 5.6–10× tùy FPGA, chủ yếu nhờ rate gấp
   đôi (128 so với 64 bit) chứ không phải do vi kiến trúc vượt trội — cần nêu rõ điều này
   khi trình bày trong báo cáo đồ án để tránh ngộ nhận "nhanh hơn thật".
2. **Ascon-AEAD128 (đồ án) vs ASCON-128a (Malal):** cùng rate 128 bit nên là so sánh
   công bằng nhất về throughput/khối, nhưng khác lớp kiến trúc (Malal xử lý 4 round
   song song/chu kỳ, đồ án xử lý 1 round/chu kỳ) nên Malal đạt Mbps/LUT cao hơn (2.44
   so với 1.667 trên Artix-7) — đánh đổi bằng Fmax thấp hơn nhiều (83 MHz so với
   182 MHz) do critical path dài hơn (4 round tổ hợp nối tiếp).
3. **Ascon-AEAD128 (đồ án) vs Ascon-128 serial (Mohamed):** hai đầu cực của trục
   diện tích–thông lượng; không có công trình nào "thắng" toàn diện, tùy ràng buộc ứng
   dụng đích (RFID thụ động cực kỳ hạn chế diện tích/công suất so với SoC APB cần
   thông lượng cao hơn).
4. Speed grade −1 trên Artix-7 của đồ án là điểm bất lợi có chủ đích ghi nhận: Fmax
   182 MHz là **cận dưới bảo thủ**, không phải giới hạn kiến trúc.

---

## 6. Tài liệu tham khảo

[1] A. R. Alharbi, A. Aljaedi, A. Aljuhni, M. K. Alghuson, H. Aldawood, and S. S. Jamal,
"Evaluating Ascon Hardware on 7-Series FPGA Devices," *IEEE Access*, vol. 12,
pp. 149076–149089, 2024, doi: 10.1109/ACCESS.2024.3471694.

[2] A. Malal, "High-Performance FPGA Implementations of Lightweight ASCON-128 and
ASCON-128a with Enhanced Throughput-to-Area Efficiency," ASELSAN Inc. and Middle
East Technical University, Ankara, Turkey. (Ngày xuất bản và tên hội nghị/tạp chí không
xuất hiện trong bản PDF thu thập được — cần bổ sung khi trích dẫn chính thức trong
luận văn; mã nguồn công khai tại
https://github.com/AhmetMALAL/ascon-vhdl.)

[3] H. A. Mohamed, M. Taher, H. M. Shousha, Z. Mohsen, M. M. Abdelrazik, Y. Ismail,
and A. Saeed, "An efficient serialized hardware implementation of the ASCON
algorithm," *Scientific Reports*, vol. 16, art. no. 23197, 2026,
doi: 10.1038/s41598-026-63223-6.
