# Vi kiến trúc — kiến trúc một vòng mỗi chu kỳ (ROUNDS_PER_CYCLE = 1)

| | |
|---|---|
| **Phiên bản** | 0.1 (nháp) |
| **Bám theo** | `docs/spec.md` phiên bản 0.1 |
| **Phạm vi** | Kiến trúc khảo sát thứ nhất — bước 3 trong quy trình làm việc |

Tài liệu này mô tả vi kiến trúc cho lõi `ascon_aead_fsm` + `ascon_perm`,
chạy **một vòng hoán vị mỗi chu kỳ đồng hồ** (`ROUNDS_PER_CYCLE = 1`,
xem `docs/spec.md` mục 4). Chưa viết Verilog ở bước này — đây là cơ sở
để bước 4 (viết RTL từ dưới lên) bám theo.

---

## 1. Sơ đồ datapath

Quy ước trạng thái: 320 bit gồm 5 từ 64 bit `S0..S4`, `S0`/`S1` là **rate**
(128 bit), `S2`/`S3`/`S4` là **capacity** (192 bit) — xem `docs/spec.md`
mục 3.

```
                                  round_idx[3:0]  (bo dem vong)
                                        |
                                        v
                              +-------------------+
                              |  case(round_idx)   |
                              |  tra RC (khong     |
                              |  dung mang lon)    |  RC = 8'h..
                              +---------+---------+
                                        |
  din[127:0] (tu APB, ---.             | rc[7:0]
  da ghep 4x32 bit)       |            |
                          v            v
                    +-----------+  +----------------------------+
                    | dem/vala- |  |                            |
   valid_bytes ---->| id_bytes  |  |      ascon_round (to hop)  |
                    | mux dem   |  |  x2 ^= rc                  |
                    +-----+-----+  |  ascon_sbox (phi tuyen)    |
                          |        |  ascon_linear (xoay-XOR)   |
                          v        +--------------+-------------+
                +-------------------+              |
                | XOR vao rate      |              | S0'..S4' (vong ke tiep)
                | S0/S1 (+ domain-  |              |
                | sep bit S4 neu la |              |
                | khoi PROC_TEXT    |              |
                | dau tien)         |              |
                +---------+---------+              |
                          |                         |
                          |   S2,S3,S4 giu nguyen    |
                          |   (chi S0/S1 doi khi     |
                          |   XOR du lieu)           |
                          v                         v
                 +----------------------------------------------+
                 |     MUX ghi thanh ghi trang thai (state_in)    |
                 |  chon 1 trong: hoan vi tiep | XOR du lieu vao  |
                 |  rate | XOR khoa (S3/S4 INIT, S2/S3 FINAL) |   |
                 |  nap IV||K||N (INIT_LOAD) | giu nguyen          |
                 +-----------------------+------------------------+
                                         |
                                         v
                     +----------------------------------------+
                     |     Thanh ghi trang thai 320 bit         |
                     |     S0 | S1 | S2 | S3 | S4  (64 bit/tu)  |
                     +--------------------+----------------------+
                                          |
                       duong hoi tiep (feedback) ve dau vao
                       ascon_round va ve MUX o tren
                                          |
                          +---------------+----------------+
                          |                                |
                          v                                v
                 S0/S1 hien tai (rate)              S3/S4 XOR khoa
                 dung de tao dout                   (khi FINAL) -> tag
                          |
        +-----------------+------------------+
        |                                    |
        v                                    v
  ma hoa: dout = rate_moi              giai ma: dout = rate_cu XOR din
  (rate sau khi XOR din)               (truoc khi rate bi ghi de = din)
        |                                    |
        +-----------------+------------------+
                          v
                 dout[127:0] (qua valid_bytes
                 mask khi la khoi cuoi)
                          |
                          v
              ve ascon_apb -> thanh ghi DOUT0..3
```

**Diễn giải luồng dữ liệu chính:**

- **Bộ đếm vòng `round_idx[3:0]`**: nạp giá trị khởi đầu `4` khi chạy `p12`,
  `8` khi chạy `p8` (đúng bảng hằng số RC — xem mục "những chỗ hay sai" #10
  trong `CLAUDE.md`), đếm lên tới `15` thì báo hoàn vị xong.
- **`ascon_round`**: khối tổ hợp thuần túy, không có thanh ghi riêng, nhận
  trạng thái hiện tại + `round_idx`, trả về trạng thái sau một vòng.
- **Đường XOR dữ liệu vào rate**: chỉ tác động `S0`/`S1`; với khối
  `PROC_TEXT` đầu tiên sau `INIT`, đồng thời XOR bit phân tách miền
  (`S4 ^= 0x8000000000000000`) — áp dụng bất kể AD rỗng hay không (mục
  7.3 `docs/spec.md`).
- **Đường xuất bản mã/bản rõ**: mã hóa xuất `dout` bằng rate *sau khi*
  XOR dữ liệu vào; giải mã xuất `dout` bằng rate *trước khi* bị ghi đè
  bởi bản mã tới (rồi mới nạp bản mã vào rate cho vòng kế). Khối cuối
  áp dụng mặt nạ `valid_bytes` cho cả đường ra và đường ghi ngược vào
  rate (byte đệm `0x01` chèn đúng vị trí `valid_bytes`).
- **Đường XOR khóa**: dùng chung đường XOR vào state nhưng nhắm khác từ
  tùy giai đoạn — `S3`/`S4` sau `p12` của `INIT`, `S2`/`S3` *trước*
  `p12` của `FINAL`; tag = `S3 XOR K0`, `S4 XOR K1` sau `p12` của
  `FINAL`.
- **Thanh ghi trạng thái 320 bit là điểm neo duy nhất** — mọi khối tổ
  hợp phía trên chỉ tính giá trị kế tiếp, không tự giữ trạng thái.

---

## 2. Bảng trạng thái FSM (`ascon_aead_fsm`)

FSM dùng lại một trạng thái `S_PERM` duy nhất cho cả `p8` lẫn `p12`
(khác nhau ở giá trị nạp cho `round_idx` và trạng thái quay về sau khi
xong), để tránh nhân đôi logic điều khiển hoán vị.

| Trạng thái | Việc làm | Điều kiện chuyển tiếp | Tín hiệu điều khiển phát ra |
|---|---|---|---|
| `S_IDLE` | Chờ `start` từ `ascon_apb`. Khi có, chốt `opcode/last/mode/valid_bytes`. `opcode=SOFT_RESET` xử lý ngay tại đây (xóa cờ nội bộ, không chuyển trạng thái). | `opcode=INIT` → `S_LOAD`. `opcode=PROC_AD` hoặc `PROC_TEXT` → `S_XOR_IN`. `opcode=FINAL` → `S_FIN_KEYXOR`. `opcode=NOP/SOFT_RESET` hoặc không có `start` → giữ `S_IDLE`. | `busy=0`. `done` = xung 1 chu kỳ từ chu kỳ hoàn tất thao tác trước (xem các trạng thái cuối). |
| `S_LOAD` | Nạp `state_in = IV \|\| K0 \|\| K1 \|\| N0 \|\| N1`. Đặt `round_idx=4`, `ret_state=S_INIT_KEYXOR`. Xóa cờ `first_pt_done`. | Luôn sang `S_PERM` sau 1 chu kỳ. | `busy=1`. Nạp thanh ghi trạng thái toàn bộ (mux state = IV/K/N). |
| `S_XOR_IN` | XOR `din` (đã áp `valid_bytes` nếu `last=1`) vào `S0/S1`. Nếu là `PROC_TEXT` đầu tiên: đồng thời XOR bit phân tách miền vào `S4`, đặt `first_pt_done=1`. Mã hóa: `dout = S0'/S1'` (rate sau XOR). Giải mã: `dout = S0/S1 XOR din` (rate trước khi bị ghi đè); nếu khối cuối, rate mới chỉ cập nhật phần `valid_bytes` + byte đệm. | `opcode=PROC_AD` **hoặc** (`PROC_TEXT` và `last=0`): `round_idx=8`, `ret_state=S_IDLE` (báo `done` ngay khi `p8` xong) → `S_PERM`. `opcode=PROC_TEXT` và `last=1`: bỏ qua `p8`, `done` phát ngay trong chu kỳ này → `S_IDLE`. | `busy=1`. `dout_valid=1` nếu là `PROC_TEXT`. `done=1` nếu là `PROC_TEXT` với `last=1` (không chạy thêm `p8`). |
| `S_PERM` | Mỗi chu kỳ: `state <= ascon_round(state, round_idx)`, `round_idx <= round_idx + 1`. | `round_idx < 15`: giữ `S_PERM`. `round_idx == 15` (vừa xử lý vòng cuối): sang `ret_state` (`S_INIT_KEYXOR`, `S_FIN_TAGXOR`, hoặc `S_IDLE`). | `busy=1`. `done=1` nếu `ret_state=S_IDLE` (trường hợp `p8` kết thúc một khối `PROC_AD`/`PROC_TEXT` không phải khối cuối). |
| `S_INIT_KEYXOR` | `S3 ^= K0`, `S4 ^= K1`. | Luôn sang `S_IDLE` sau 1 chu kỳ. | `busy=1` trong chu kỳ này, `done=1`. |
| `S_FIN_KEYXOR` | `S2 ^= K0`, `S3 ^= K1`. Đặt `round_idx=4`, `ret_state=S_FIN_TAGXOR`. | Luôn sang `S_PERM` sau 1 chu kỳ. | `busy=1`. |
| `S_FIN_TAGXOR` | Tính `tag = {S3 ^ K0, S4 ^ K1}`. Nếu `mode=1` (giải mã): so `tag` với `tag_in` đã chốt (từ `TAGIN0..3`), đặt `tag_fail`. | Luôn sang `S_IDLE` sau 1 chu kỳ. | `busy=1`, `tag_valid=1`, `done=1`, `tag_fail` hợp lệ nếu `mode=1`. |

Ghi chú:
- `busy` là tổ hợp của "khác `S_IDLE`" (trừ chu kỳ `S_IDLE` không có
  `start`).
- `done` luôn là **xung 1 chu kỳ**, đúng để `ascon_apb` chốt cờ dính
  `STATUS.done` (mục 6.2 `docs/spec.md`).
- Cờ `first_pt_done` (nội bộ FSM) reset ở `S_LOAD`, đảm bảo bit phân
  tách miền chỉ XOR đúng một lần mỗi phiên, kể cả khi AD rỗng — đúng
  yêu cầu mục 7.3 `docs/spec.md` và mục #5/#6 trong danh sách lỗi hay
  gặp của `CLAUDE.md`.
- `p8` **luôn** chạy sau mỗi khối `PROC_AD` (kể cả khối `PROC_AD` cuối
  cùng) nhưng **không bao giờ** chạy sau khối `PROC_TEXT` cuối cùng —
  đúng mục #4 trong danh sách lỗi hay gặp.

---

## 3. Bảng ngân sách chu kỳ

Gọi `A` = số khối AD (`A = 0` nếu AD rỗng), `T` = số khối bản rõ/bản mã
(`T ≥ 1` luôn, kể cả PT rỗng — mục 8.4 `docs/spec.md`):
`A = ceil((len(AD)+1)/16)` nếu `len(AD)>0` else `0`,
`T = ceil((len(PT)+1)/16)`.

Chu kỳ tính trên lõi `ascon_aead_fsm` (không tính chu kỳ bus APB để ghi
`KEY/NONCE/DIN` hay đọc `DOUT/TAG` — xem ghi chú cuối bảng):

| Giai đoạn | Số chu kỳ | Thành phần |
|---|---|---|
| `INIT` | 14 | 1 (`S_LOAD`) + 12 (`p12`) + 1 (`S_INIT_KEYXOR`) |
| Mỗi khối `PROC_AD` | 9 | 1 (`S_XOR_IN`) + 8 (`p8`) |
| Khối `PROC_TEXT` không phải cuối | 9 | 1 (`S_XOR_IN`) + 8 (`p8`) |
| Khối `PROC_TEXT` cuối | 1 | 1 (`S_XOR_IN`, không chạy `p8`) |
| `FINAL` | 14 | 1 (`S_FIN_KEYXOR`) + 12 (`p12`) + 1 (`S_FIN_TAGXOR`) |

**Công thức tổng:**

```
N_cycle(A, T) = 14 (INIT) + 9*A + 9*(T-1) + 1 + 14 (FINAL)
              = 20 + 9*(A + T)
```

**Ví dụ cụ thể:**

| Trường hợp | A | T | N_cycle | Ghi chú |
|---|---|---|---|---|
| AD rỗng, PT rỗng | 0 | 1 | 20 + 9·1 = **29** | tương ứng KAT `Count=1` |
| AD = 1 byte, PT rỗng | 1 | 1 | 20 + 9·2 = **38** | tương ứng KAT `Count=2` |
| AD rỗng, PT = 16 byte (1 khối tròn) | 0 | 2 | 20 + 9·2 = **38** | PT tròn 16 byte vẫn cần khối đệm phụ → T=2 |
| AD rỗng, PT = 10 byte | 0 | 1 | 20 + 9·1 = **29** | khối duy nhất, `valid_bytes=10` |
| AD = 2 khối, PT = 3 khối | 2 | 3 | 20 + 9·5 = **65** | ví dụ thông điệp dài |

Ghi chú:
- Chưa tính chu kỳ bus APB: mỗi khối cần 4 lần ghi `DIN0..3` + 1 lần
  ghi `CMD` (+ 4 lần đọc `DOUT0..3` với `PROC_TEXT`), cộng thời gian
  polling `STATUS.done`. Số chu kỳ bus phụ thuộc tần số polling của
  phần mềm điều khiển, không cố định như phần lõi nên không đưa vào
  công thức trên.
- `SOFT_RESET` và `NOP` xử lý trong 1 chu kỳ tại `S_IDLE`, không đáng
  kể trong ngân sách.
- Kiến trúc khảo sát thứ hai (`ROUNDS_PER_CYCLE=2`, bước 9 trong quy
  trình làm việc) sẽ giảm gần một nửa số chu kỳ cho mỗi `p8`/`p12`,
  đánh đổi bằng đường tổ hợp dài hơn — không thuộc phạm vi tài liệu
  này.

---

## 4. Danh sách module RTL và cổng vào/ra

Theo đúng quy tắc phụ thuộc một chiều trong `CLAUDE.md`:
`rtl/core/` không tham chiếu `rtl/ip/`. Thứ tự xây dựng từ dưới lên:
`ascon_sbox` + `ascon_linear` → `ascon_round` → `ascon_perm` →
`ascon_aead_fsm` → `ascon_apb`.

### 4.1. `rtl/core/ascon_sbox.v`

Lớp phi tuyến (5-bit S-box áp song song trên 64 vị trí bit), nhận
trạng thái **đã XOR hằng số vòng**, trả về trạng thái sau lớp phi
tuyến (chưa qua lớp tuyến tính).

| Cổng | Chiều | Rộng | Mô tả |
|---|---|---|---|
| `x0_i, x1_i, x2_i, x3_i, x4_i` | vào | 64 | 5 từ trạng thái, `x2_i` đã XOR hằng số vòng |
| `x0_o, x1_o, x2_o, x3_o, x4_o` | ra | 64 | 5 từ sau lớp phi tuyến (tổ hợp thuần túy) |

### 4.2. `rtl/core/ascon_linear.v`

Lớp khuếch tán tuyến tính (xoay-phải + XOR trên từng từ).

| Cổng | Chiều | Rộng | Mô tả |
|---|---|---|---|
| `x0_i, x1_i, x2_i, x3_i, x4_i` | vào | 64 | 5 từ sau lớp phi tuyến |
| `x0_o, x1_o, x2_o, x3_o, x4_o` | ra | 64 | 5 từ sau lớp tuyến tính = đầu ra một vòng hoán vị (tổ hợp thuần túy) |

### 4.3. `rtl/core/ascon_round.v`

Một vòng hoán vị hoàn chỉnh: XOR hằng số vòng + `ascon_sbox` +
`ascon_linear`. Tra hằng số vòng bằng `case`, không dùng mảng lớn
(tránh suy ra Block RAM — mục 5 `CLAUDE.md`).

| Cổng | Chiều | Rộng | Mô tả |
|---|---|---|---|
| `x0_i, x1_i, x2_i, x3_i, x4_i` | vào | 64 | 5 từ trạng thái đầu vào |
| `round_idx` | vào | 4 | Chỉ số vòng (4–15), tra ra hằng số `RC` qua `case` |
| `x0_o, x1_o, x2_o, x3_o, x4_o` | ra | 64 | 5 từ trạng thái sau một vòng (tổ hợp thuần túy) |

### 4.4. `rtl/core/ascon_perm.v`

Bộ máy hoán vị có trạng thái: giữ thanh ghi 320 bit, chạy `ascon_round`
lặp lại theo `round_idx`, cho phép nạp đè trạng thái (dùng để XOR dữ
liệu/khóa giữa các lần hoán vị mà không tốn thêm module).

| Cổng | Chiều | Rộng | Mô tả |
|---|---|---|---|
| `clk, rst_n` | vào | 1 | Xung nhịp, reset bất đồng bộ tích cực mức thấp |
| `state_i` | vào | 320 | Giá trị nạp khi `load=1`: `{S0,S1,S2,S3,S4}`, `S0` ở bit cao nhất |
| `load` | vào | 1 | 1 chu kỳ: ghi đè thanh ghi trạng thái bằng `state_i`, không chạy vòng |
| `start` | vào | 1 | 1 chu kỳ: bắt đầu chạy hoán vị từ `round_start` tới vòng 15 |
| `round_start` | vào | 4 | Giá trị nạp cho bộ đếm vòng: `4` cho `p12`, `8` cho `p8` |
| `busy` | ra | 1 | 1 khi đang chạy hoán vị |
| `done` | ra | 1 | Xung 1 chu kỳ khi vừa chạy xong vòng 15 |
| `state_o` | ra | 320 | Giá trị thanh ghi trạng thái hiện tại, cùng định dạng `state_i` |

### 4.5. `rtl/core/ascon_aead_fsm.v`

FSM điều khiển toàn bộ luồng AEAD theo bảng mục 2, sở hữu một thực thể
`ascon_perm` và toàn bộ logic XOR dữ liệu/khóa/đệm/so tag.

| Cổng | Chiều | Rộng | Mô tả |
|---|---|---|---|
| `clk, rst_n` | vào | 1 | Xung nhịp, reset bất đồng bộ tích cực mức thấp |
| `start` | vào | 1 | Xung: có lệnh mới hợp lệ (tương ứng ghi `CMD` với `opcode≠0`) |
| `opcode` | vào | 3 | Theo mã hóa mục 6.1 `docs/spec.md` |
| `last` | vào | 1 | 1 = khối cuối của giai đoạn hiện tại |
| `mode` | vào | 1 | 0 = mã hóa, 1 = giải mã |
| `valid_bytes` | vào | 5 | Số byte hợp lệ của khối (0–16), có nghĩa khi `last=1` |
| `key` | vào | 128 | Khóa, đã chốt từ `KEY0..3` |
| `nonce` | vào | 128 | Nonce, đã chốt từ `NONCE0..3` |
| `din` | vào | 128 | Khối dữ liệu vào, đã chốt từ `DIN0..3` |
| `tag_in` | vào | 128 | Tag nhận được, đã chốt từ `TAGIN0..3` (dùng khi `FINAL` + giải mã) |
| `busy` | ra | 1 | 1 khi đang xử lý, không nhận lệnh mới |
| `done` | ra | 1 | Xung 1 chu kỳ khi thao tác hiện tại hoàn tất |
| `dout` | ra | 128 | Khối dữ liệu ra (đã áp `valid_bytes` nếu khối cuối) |
| `dout_valid` | ra | 1 | 1 khi `dout` hợp lệ (sau lệnh `PROC_TEXT`) |
| `tag` | ra | 128 | Tag tính được (sau `FINAL`) |
| `tag_valid` | ra | 1 | 1 khi `tag` hợp lệ |
| `tag_fail` | ra | 1 | 1 khi tag không khớp `tag_in` (chỉ có nghĩa khi `mode=1`, sau `FINAL`) |

### 4.6. `rtl/ip/ascon_apb.v`

Đơn vị tổng hợp — giao diện APB slave, thanh ghi theo register map
mục 6 `docs/spec.md`, ghép 4 lần ghi 32 bit thành khối 128 bit, sở
hữu một thực thể `ascon_aead_fsm`.

| Cổng | Chiều | Rộng | Mô tả |
|---|---|---|---|
| `pclk` | vào | 1 | Xung nhịp hệ thống |
| `presetn` | vào | 1 | Reset bất đồng bộ, tích cực mức thấp |
| `psel` | vào | 1 | Chọn slave |
| `penable` | vào | 1 | Đánh dấu pha ACCESS |
| `pwrite` | vào | 1 | 1 = ghi, 0 = đọc |
| `paddr` | vào | 8 | Địa chỉ thanh ghi |
| `pwdata` | vào | 32 | Dữ liệu ghi |
| `prdata` | ra | 32 | Dữ liệu đọc |
| `pready` | ra | 1 | Slave sẵn sàng kết thúc giao dịch |
| `pslverr` | ra | 1 | Báo lỗi truy cập (vd. lệnh xử lý khi `din_full=0`) |

---

## 5. Việc chưa làm ở tài liệu này

- Chưa định nghĩa chi tiết mạch đệm/hợp nhất byte theo `valid_bytes`
  (mux 16 làn byte) — để lại cho lúc viết RTL `ascon_aead_fsm`, bám
  theo hành vi đã kiểm chứng trong `model/ascon_model.py` (`pad16`,
  nhánh khối cuối của `decrypt`).
- Chưa thiết kế chi tiết logic `pslverr` và các trường hợp lỗi giao
  thức APB khác ngoài `din_full=0`.
- Chưa khảo sát kiến trúc `ROUNDS_PER_CYCLE=2` (bước 9 quy trình làm
  việc).
