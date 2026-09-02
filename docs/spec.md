# Đặc tả lõi IP Ascon-AEAD128 tích hợp AMBA APB

| | |
|---|---|
| **Phiên bản** | 0.1 (nháp) |
| **Ngày** | *điền ngày* |
| **Tác giả** | Hồ Thiện Nhân — MSSV 23521073 |
| **GVHD** | ThS. Tạ Trí Đức |
| **Chuẩn tham chiếu** | NIST SP 800-232 · AMBA APB Protocol Specification |

---

## 1. Giới thiệu

Tài liệu này đặc tả lõi IP phần cứng thực hiện thuật toán mã hóa xác thực hạng nhẹ **Ascon-AEAD128**, đóng gói với giao diện **AMBA APB slave** để tích hợp vào hệ thống SoC.

Đây là tài liệu **chốt** — mọi thiết kế RTL và mọi testbench đều bám theo. Thay đổi nội dung tài liệu này phải kèm cập nhật số phiên bản.

---

## 2. Chốt biến thể thuật toán

> Đồ án hiện thực **Ascon-AEAD128 theo NIST SP 800-232**: rate 128 bit, hoán vị trung gian p8, biểu diễn little-endian, IV = `0x00001000808c0001`.

Đây **không phải** Ascon-128 của bản đệ trình v1.2. Hai thuật toán khác nhau và cho ra bản mã khác nhau hoàn toàn:

| | Ascon-128 (v1.2) | **Ascon-AEAD128 (SP 800-232)** |
|---|---|---|
| Rate | 64 bit | **128 bit** |
| Hoán vị trung gian | p6 | **p8** |
| Thứ tự byte | Big-endian | **Little-endian** |
| IV | `0x80400c0600000000` | **`0x00001000808c0001`** |

**Lý do chọn:** SP 800-232 là tiêu chuẩn chính thức còn hiệu lực (xuất bản 8/2025), và bộ test vector đi kèm là căn cứ nghiệm thu khách quan cho đồ án. Tên đề tài dùng cách gọi quen thuộc "ASCON-128" nhưng nội dung bám chuẩn NIST.

---

## 3. Tham số thuật toán

| Tham số | Giá trị |
|---|---|
| Độ rộng trạng thái | 320 bit (5 từ 64 bit: S0…S4) |
| Rate / Capacity | 128 / 192 bit |
| Khóa (K) | 128 bit |
| Nonce (N) | 128 bit |
| Tag (T) | 128 bit |
| Hoán vị khởi tạo và hoàn tất | p12 |
| Hoán vị trung gian | p8 |
| Kích thước khối dữ liệu | 128 bit = 16 byte |
| Độ dài AD và bản rõ | tùy ý, kể cả rỗng |

**Giới hạn an toàn theo chuẩn:**
- Nonce **bắt buộc duy nhất** với mỗi lần mã hóa dưới cùng một khóa
- Tổng dữ liệu dưới một khóa ≤ 2⁵⁴ byte
- Số lần giải mã thất bại dưới một khóa ≤ 2⁹⁶

---

## 4. Tham số cấu hình lõi

| Tham số | Giá trị mặc định | Ghi chú |
|---|---|---|
| `ROUNDS_PER_CYCLE` | 1 | Số vòng hoán vị mỗi chu kỳ; đổi thành 2 cho kiến trúc khảo sát |
| `APB_ADDR_WIDTH` | 8 | Đủ cho dải thanh ghi 0x00–0x6C |
| `APB_DATA_WIDTH` | 32 | Cố định theo chuẩn APB |

---

## 5. Môi trường phát triển

| Hạng mục | Giá trị |
|---|---|
| Công cụ tổng hợp | Vivado 2022.2 (64-bit) |
| Thiết bị đích | `xc7a35tcpg236-1` — Artix-7, board Basys 3 |
| Speed grade | `-1` |
| Chế độ tổng hợp | Out-of-Context (OOC) |
| Công cụ mô phỏng | Icarus Verilog 14.0 |

**Ghi chú:** Speed grade `-1` là mức **chậm nhất** trong họ Artix-7 (các mức nhanh hơn là `-2`, `-3`). Vì vậy Fmax báo cáo được từ bước quét timing (bước 7 trong quy trình làm việc) là con số **bảo thủ** — cùng một thiết kế trên chip tốc độ cao hơn trong cùng họ sẽ đạt Fmax cao hơn số đo được ở đây.

---

## 6. Giao diện tín hiệu

### 6.1. Tín hiệu hệ thống

| Tên | Chiều | Rộng | Mô tả |
|---|---|---|---|
| `pclk` | vào | 1 | Xung nhịp hệ thống |
| `presetn` | vào | 1 | Reset bất đồng bộ, tích cực mức thấp |

### 6.2. Tín hiệu APB slave

| Tên | Chiều | Rộng | Mô tả |
|---|---|---|---|
| `psel` | vào | 1 | Chọn slave |
| `penable` | vào | 1 | Đánh dấu pha ACCESS |
| `pwrite` | vào | 1 | 1 = ghi, 0 = đọc |
| `paddr` | vào | 8 | Địa chỉ thanh ghi |
| `pwdata` | vào | 32 | Dữ liệu ghi |
| `prdata` | ra | 32 | Dữ liệu đọc |
| `pready` | ra | 1 | Slave sẵn sàng kết thúc giao dịch |
| `pslverr` | ra | 1 | Báo lỗi truy cập |

---

## 7. Register map

Địa chỉ tính theo byte, mọi thanh ghi rộng 32 bit và căn theo từ.

| Offset | Tên | R/W | Mô tả |
|---|---|---|---|
| `0x00` | `CMD` | W | Thanh ghi lệnh — xem 7.1 |
| `0x04` | `STATUS` | R | Thanh ghi trạng thái — xem 7.2 |
| `0x10`–`0x1C` | `KEY0`–`KEY3` | W | Khóa 128 bit. **Chỉ ghi**, đọc trả về 0 |
| `0x20`–`0x2C` | `NONCE0`–`NONCE3` | W | Nonce 128 bit |
| `0x30`–`0x3C` | `DIN0`–`DIN3` | W | Khối dữ liệu vào 128 bit |
| `0x40`–`0x4C` | `DOUT0`–`DOUT3` | R | Khối dữ liệu ra 128 bit |
| `0x50`–`0x5C` | `TAG0`–`TAG3` | R | Tag do lõi tính ra |
| `0x60`–`0x6C` | `TAGIN0`–`TAGIN3` | W | Tag nhận được, dùng khi giải mã |

**Quy ước thứ tự từ:** với mọi trường 128 bit, thanh ghi chỉ số 0 chứa 32 bit **có trọng số thấp nhất**. Ví dụ khóa `K` gồm 16 byte `k[0..15]` thì `KEY0 = {k[3],k[2],k[1],k[0]}`.

### 7.1. Thanh ghi CMD (0x00, chỉ ghi)

| Bit | Tên | Mô tả |
|---|---|---|
| `[2:0]` | `opcode` | 0 = NOP · 1 = INIT · 2 = PROC_AD · 3 = PROC_TEXT · 4 = FINAL · 7 = SOFT_RESET |
| `[3]` | `last` | 1 = đây là khối cuối của giai đoạn hiện tại |
| `[4]` | `mode` | 0 = mã hóa · 1 = giải mã |
| `[12:8]` | `valid_bytes` | Số byte hợp lệ của khối, giá trị 0–16. Chỉ có ý nghĩa khi `last = 1` |
| còn lại | — | Dự phòng, ghi 0 |

Ghi vào `CMD` với `opcode ≠ 0` sẽ khởi động thao tác tương ứng và tự động xóa cờ `done`.

### 7.2. Thanh ghi STATUS (0x04, chỉ đọc)

| Bit | Tên | Mô tả |
|---|---|---|
| `[0]` | `busy` | 1 = lõi đang xử lý, không nhận lệnh mới |
| `[1]` | `done` | 1 = thao tác vừa rồi đã xong. Cờ dính, xóa khi ghi `CMD` mới |
| `[2]` | `dout_valid` | 1 = `DOUT` chứa dữ liệu hợp lệ |
| `[3]` | `tag_valid` | 1 = `TAG` chứa tag hợp lệ (sau `FINAL`) |
| `[4]` | `tag_fail` | 1 = tag không khớp (chỉ có nghĩa khi giải mã, sau `FINAL`) |
| `[5]` | `din_full` | 1 = đã nhận đủ 4 từ vào `DIN`, sẵn sàng nhận lệnh xử lý |

---

## 8. Trình tự thao tác

### 8.1. Mã hóa

```
1. Ghi KEY0..KEY3, NONCE0..NONCE3
2. Ghi CMD = {opcode=INIT, mode=0}
   Chờ STATUS.done == 1

3. Với mỗi khối AD (bỏ qua hoàn toàn nếu AD rỗng):
     Ghi DIN0..DIN3
     Ghi CMD = {opcode=PROC_AD, last, valid_bytes}
     Chờ STATUS.done == 1

4. Với mỗi khối bản rõ (LUÔN có ít nhất một khối, kể cả khi bản rõ rỗng):
     Ghi DIN0..DIN3
     Ghi CMD = {opcode=PROC_TEXT, last, valid_bytes}
     Chờ STATUS.done == 1
     Đọc DOUT0..DOUT3  → lấy valid_bytes byte đầu

5. Ghi CMD = {opcode=FINAL}
   Chờ STATUS.done == 1
   Đọc TAG0..TAG3
```

### 8.2. Giải mã

Giống hệt trình tự trên với `mode = 1`, thêm hai khác biệt:

- Trước khi ghi `CMD = FINAL`, phải ghi `TAGIN0..TAGIN3` là tag nhận được
- Sau `FINAL`, kiểm tra `STATUS.tag_fail`. Nếu bằng 1 thì **hủy toàn bộ bản rõ đã đọc ra**

### 8.3. Hai trường hợp biên bắt buộc xử lý đúng

| Trường hợp | Hành vi đúng |
|---|---|
| **AD rỗng** | Bỏ qua hoàn toàn bước 3, không gửi lệnh `PROC_AD` lần nào. Lõi vẫn phải XOR bit phân tách miền khi nhận lệnh `PROC_TEXT` đầu tiên |
| **Bản rõ rỗng** | Vẫn phải gửi **một** lệnh `PROC_TEXT` với `last = 1` và `valid_bytes = 0`. `DOUT` không chứa byte hợp lệ nào |

---

## 9. Quyết định thiết kế và lý do

### 9.1. Thanh ghi KEY chỉ ghi

Đọc `KEY0`–`KEY3` luôn trả về 0. Đây là nguyên tắc cơ bản của IP mật mã: không bao giờ để khóa đọc ngược ra qua bus, kể cả bởi phần mềm có đặc quyền.

### 9.2. Dùng opcode thay vì nhiều bit điều khiển rời

Thanh ghi `CMD` dùng trường `opcode` 3 bit thay vì các bit `start`, `is_ad`, `is_final` riêng lẻ. Lý do: các thao tác loại trừ lẫn nhau, nên mã hóa thành opcode giúp tránh trạng thái vô nghĩa (ví dụ vừa `is_ad` vừa `is_final`) và giảm số nhánh phải kiểm chứng.

### 9.3. Bus 32 bit, khối 128 bit

Mỗi khối cần bốn lần ghi `DIN`. Lõi đếm số từ đã nhận và đặt `STATUS.din_full = 1` khi đủ bốn. Ghi lệnh xử lý khi `din_full = 0` bị bỏ qua và `pslverr` được kích hoạt.

### 9.4. Trường `valid_bytes` cho logic đệm

Vì độ dài dữ liệu tùy ý nên khối cuối có thể lẻ byte. Trường `valid_bytes` cho lõi biết chèn byte `0x01` ở vị trí nào. Giá trị 16 nghĩa là khối đầy đủ và khối đệm sẽ là khối tiếp theo — phần mềm chịu trách nhiệm gửi thêm khối đệm đó theo công thức `số khối = ceil((độ dài + 1) / 16)`.

### 9.5. Hạn chế đã biết — xuất bản rõ trước khi kiểm tra tag

Ascon là thuật toán **online**: khối bản mã thứ *i* được tạo ra ngay khi có khối bản rõ thứ *i*, và tag chỉ tính được sau khi xử lý hết dữ liệu. Do đó khi giải mã, các khối bản rõ được xuất ra `DOUT` **trước khi** tag được kiểm tra.

Đặc tả AEAD yêu cầu không tiết lộ bản rõ khi tag sai. Với giao diện theo khối, lõi không thể tự đảm bảo điều này mà không có bộ đệm chứa cả thông điệp — chi phí phần cứng không chấp nhận được cho một IP hạng nhẹ.

**Giải pháp áp dụng:**
- Lõi giữ `DOUT` của **khối cuối cùng** cho tới khi `FINAL` hoàn tất, và chặn hẳn nếu `tag_fail = 1`
- Với các khối trước đó, trách nhiệm hủy dữ liệu thuộc về phần mềm điều khiển
- Yêu cầu này được ghi rõ trong tài liệu tích hợp

Đây là cách các IP AEAD thương mại xử lý, và là một điểm đáng thảo luận trong báo cáo.

---

## 10. Phạm vi đồ án

| Thực hiện | Không thực hiện |
|---|---|
| Ascon-AEAD128, cả mã hóa và giải mã | Ascon-Hash256, XOF128, CXOF128 |
| Giao diện APB slave đầy đủ | Bus AHB, AXI |
| Kiểm chứng bằng test vector NIST | Chống tấn công kênh bên bằng mặt nạ |
| Tổng hợp OOC và báo cáo PPA | Cắt ngắn tag, che nonce |
| Khảo sát ít nhất hai phương án kiến trúc | Cơ chế chống tấn công phát lại |

**Nội dung mở rộng**, thực hiện nếu có điều kiện tiếp cận phần cứng: hệ thống demo qua UART và bitstream chạy trên board FPGA.

---

## 11. Tiêu chí nghiệm thu

| Mức | Tiêu chí | Cần phần cứng |
|---|---|---|
| Bắt buộc | Pass 100 % test vector NIST ở mô phỏng RTL | Không |
| Bắt buộc | Pass test vector ở mô phỏng gate-level sau đặt chỗ và đi dây | Không |
| Bắt buộc | Không có vi phạm timing sau implementation | Không |
| Bắt buộc | Báo cáo PPA cho ít nhất hai phương án kiến trúc | Không |
| Bắt buộc | Tag sai khi giải mã thì `tag_fail = 1` và khối cuối bị chặn | Không |
| Mở rộng | Bitstream chạy trên board, chạy KAT qua UART | Có |

---

## 12. Tài liệu tham chiếu

| Ký hiệu | Tài liệu |
|---|---|
| [1] | NIST SP 800-232, *Ascon-Based Lightweight Cryptography Standards for Constrained Devices*, 8/2025 |
| [2] | ARM IHI 0024, *AMBA APB Protocol Specification* |
| [3] | Bộ test vector `LWC_AEAD_KAT_128_128.txt`, NIST Lightweight Cryptography Project |

---

## Lịch sử thay đổi

| Phiên bản | Ngày | Nội dung |
|---|---|---|
| 0.1 | *điền ngày* | Bản nháp đầu tiên |
