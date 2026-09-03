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
  `STATUS.done` (mục 7.2 `docs/spec.md`).
- Cờ `first_pt_done` (nội bộ FSM) reset ở `S_LOAD`, đảm bảo bit phân
  tách miền chỉ XOR đúng một lần mỗi phiên, kể cả khi AD rỗng — đúng
  yêu cầu mục 8.3 `docs/spec.md` và mục #5/#6 trong danh sách lỗi hay
  gặp của `CLAUDE.md`.
- `p8` **luôn** chạy sau mỗi khối `PROC_AD` (kể cả khối `PROC_AD` cuối
  cùng) nhưng **không bao giờ** chạy sau khối `PROC_TEXT` cuối cùng —
  đúng mục #4 trong danh sách lỗi hay gặp.

---

## 3. Bảng ngân sách chu kỳ

Gọi `A` = số khối AD (`A = 0` nếu AD rỗng), `T` = số khối bản rõ/bản mã
(`T ≥ 1` luôn, kể cả PT rỗng — mục 9.4 `docs/spec.md`):
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

### 3.1. Ngân sách chu kỳ khi `ROUNDS_PER_CYCLE` > 1

Kiến trúc khảo sát thứ hai (bước 9 quy trình làm việc, chi tiết dự
đoán/so sánh ở mục 6) chạy 2 vòng hoán vị mỗi chu kỳ: `p12` còn 6 chu
kỳ (thay vì 12), `p8` còn 4 chu kỳ (thay vì 8) — FSM (`S_LOAD`,
`S_XOR_IN`, `S_INIT_KEYXOR`, ...) không đổi, chỉ riêng số chu kỳ nằm
trong `S_PERM` giảm một nửa:

| Giai đoạn | Số chu kỳ (RPC=1) | Số chu kỳ (RPC=2) | Thành phần (RPC=2) |
|---|---|---|---|
| `INIT` | 14 | **8** | 1 (`S_LOAD`) + 6 (`p12`) + 1 (`S_INIT_KEYXOR`) |
| Mỗi khối `PROC_AD` | 9 | **5** | 1 (`S_XOR_IN`) + 4 (`p8`) |
| Khối `PROC_TEXT` không phải cuối | 9 | **5** | 1 (`S_XOR_IN`) + 4 (`p8`) |
| Khối `PROC_TEXT` cuối | 1 | 1 | không đổi — không chạy `p8` |
| `FINAL` | 14 | **8** | 1 (`S_FIN_KEYXOR`) + 6 (`p12`) + 1 (`S_FIN_TAGXOR`) |

**Công thức tổng (RPC=2):**

```
N_cycle_2(A, T) = 8 (INIT) + 5*A + 5*(T-1) + 1 + 8 (FINAL)
                = 12 + 5*(A + T)
```

**Ví dụ cụ thể** (so với `N_cycle` ở bảng RPC=1 phía trên):

| Trường hợp | A | T | N_cycle (RPC=1) | N_cycle (RPC=2) | Giảm |
|---|---|---|---|---|---|
| AD rỗng, PT rỗng | 0 | 1 | 29 | 12 + 5·1 = **17** | 41 % |
| AD = 1 byte, PT rỗng | 1 | 1 | 38 | 12 + 5·2 = **22** | 42 % |
| AD rỗng, PT = 16 byte (1 khối tròn) | 0 | 2 | 38 | 12 + 5·2 = **22** | 42 % |
| AD rỗng, PT = 10 byte | 0 | 1 | 29 | 12 + 5·1 = **17** | 41 % |
| AD = 2 khối, PT = 3 khối | 2 | 3 | 65 | 12 + 5·5 = **37** | 43 % |

Không giảm đúng một nửa vì phần chu kỳ điều khiển cố định
(`S_LOAD`/`S_XOR_IN`/`S_INIT_KEYXOR`/`S_FIN_KEYXOR`/`S_FIN_TAGXOR`)
không co lại theo `ROUNDS_PER_CYCLE` — chỉ riêng số chu kỳ chạy trong
`S_PERM` (`p8`/`p12`) mới giảm đúng một nửa.

**Tổng quát cho `ROUNDS_PER_CYCLE=R` bất kỳ chia hết 12 và 8** (R=1,2,4
đều thỏa — mục 6.1): `p12` còn `12/R` chu kỳ, `p8` còn `8/R` chu kỳ,
`INIT=FINAL=2+12/R`, mỗi khối không cuối `=1+8/R`:

```
N_cycle_R(A, T) = 2*(2 + 12/R) + (1+8/R)*A + (1+8/R)*(T-1) + 1
                = (3 + 24/R) + (1 + 8/R)*(A + T)
```

Với R=4: `INIT=FINAL=2+3=5`, mỗi khối không cuối `=1+2=3`,
`N_cycle_4(A,T) = 11 + 3*(A+T)` (ví dụ AD rỗng/PT rỗng: `11+3=14`,
so với 29 ở RPC=1 và 17 ở RPC=2).

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
| `opcode` | vào | 3 | Theo mã hóa mục 7.1 `docs/spec.md` |
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
mục 7 `docs/spec.md`, ghép 4 lần ghi 32 bit thành khối 128 bit, sở
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
- Kiến trúc `ROUNDS_PER_CYCLE=2` (bước 9 quy trình làm việc): đã
  khảo sát — xem mục 3.1 (ngân sách chu kỳ) và mục 6 (dự đoán và so
  sánh với số đo thật, `reports/ppa.csv` dòng `2rpcc`).

---

## 6. Dự đoán cho kiến trúc hai vòng mỗi chu kỳ

Mục này ghi lại **dự đoán** trước khi chạy `make impl`/`make report`
cho `ROUNDS_PER_CYCLE=2`, để sau đó so với số đo thật (bước 9 quy
trình làm việc). Cơ sở dự đoán là timing report thật của kiến trúc
`ROUNDS_PER_CYCLE=1` đã có (`reports/ppa.csv` dòng `1rpcc`,
`reports/timing_critical.rpt` — snapshot dò thử tại chu kỳ 6.000 ns
từ phiên làm việc trước, không phải chu kỳ 5.6 ns cuối cùng đã lưu),
không phải suy đoán suông. File checkpoint/report cuối cùng, tái tạo
được và không ghi đè lẫn nhau giữa hai kiến trúc, nằm ở
`reports/*_rpc1.*` và `reports/*_rpc2.*` (xem mục 6.6).

### 6.1. Vì sao chọn nhân đôi tổ hợp thay vì thêm tầng thanh ghi

`ROUNDS_PER_CYCLE=2` instantiate `ascon_round` hai lần **nối tiếp
thuần tổ hợp** trong `ascon_perm` (không thêm thanh ghi trung gian):
vòng thứ nhất nhận `round_idx` hiện tại, vòng thứ hai nhận
`round_idx+1`, kết quả vòng thứ hai mới được chốt vào thanh ghi
trạng thái 320 bit ở cạnh lên kế tiếp. Bộ đếm `round_idx` nhảy 2 mỗi
chu kỳ thay vì 1. `p12` (12 vòng, bắt đầu tại index 4) chạy 6 lượt
chu kỳ (index 4,6,8,10,12,14); `p8` (8 vòng, bắt đầu tại index 8)
chạy 4 lượt (index 8,10,12,14) — cả hai chẵn nên không có vòng lẻ dư
ra, không cần logic xử lý trường hợp lẻ.

### 6.2. Dự đoán ngân sách chu kỳ

Suy trực tiếp từ mục 3: mỗi giai đoạn tốn bằng nửa số vòng hoán vị
cộng phần điều khiển không đổi:

| Giai đoạn | RPC=1 | RPC=2 | Ghi chú |
|---|---|---|---|
| `INIT` | 14 = 1+12+1 | **8** = 1+6+1 | `p12` còn 6 chu kỳ |
| `FINAL` | 14 = 1+12+1 | **8** = 1+6+1 | `p12` còn 6 chu kỳ |
| Khối `PROC_AD` / `PROC_TEXT` không cuối | 9 = 1+8 | **5** = 1+4 | `p8` còn 4 chu kỳ |
| Khối `PROC_TEXT` cuối | 1 | 1 | không đổi — không chạy `p8` |

Công thức tổng dự đoán: `N_cycle_2(A,T) = 12 + 5·(A+T)` (so với
`N_cycle_1(A,T) = 20 + 9·(A+T)` ở mục 3). Tỉ lệ giảm dao động
**55–57 %** tùy trường hợp (không đúng bằng một nửa, vì phần chu kỳ
điều khiển cố định `S_LOAD`/`S_XOR_IN`/`S_INIT_KEYXOR`/... không co
lại theo `ROUNDS_PER_CYCLE`): ví dụ AD rỗng/PT rỗng đi từ 29 → 17
chu kỳ (giảm 41 %), AD=2/PT=3 đi từ 65 → 37 chu kỳ (giảm 43 %).

### 6.3. Dự đoán tài nguyên (LUT/FF)

Đường nền (RPC=1, `reports/ppa.csv`): `LUT_core=1438`, `FF_core=732`,
`LUT_total=1556`, `FF_total=1517`. Trong đó phần lớn LUT của
`u_perm` (1413/1438 theo `report_utilization_hierarchical_rpc1.rpt`) là
logic tổ hợp của **một** `ascon_round` (S-box song song 64×5-bit +
lớp tuyến tính + case tra hằng số vòng), không phải logic điều
khiển/mux thanh ghi (phần đó nhỏ, ước lượng vài trăm LUT).

- **FF: dự đoán không đổi** (~732 lõi / ~1517 tổng) — thanh ghi
  trạng thái vẫn 320 bit, bộ đếm `round_idx` vẫn 4 bit, không thêm
  phần tử tuần tự nào khi nhân đôi khối tổ hợp.
- **LUT: dự đoán tăng ~70–90 %**, tức `LUT_core` khoảng
  **2400–2700**, `LUT_total` khoảng **2500–2850**. Không tăng đúng
  gấp đôi vì phần mux ghi thanh ghi trạng thái (chọn `round_result`
  so với `load`/giữ nguyên) không nhân đôi, chỉ có khối `ascon_round`
  thứ hai là logic hoàn toàn mới.

### 6.4. Dự đoán Fmax và tỉ lệ logic/route trên đường tới hạn mới

Đường tới hạn hiện tại của RPC=1 (`reports/timing_critical.rpt` của
phiên trước, đo tại chu kỳ thử 6.000 ns — snapshot dò thử, khác chu
kỳ 5.6 ns cuối cùng đã lưu ở `reports/timing_critical_rpc1.rpt`, xem
mục 6.6) đi xuyên qua đúng một `ascon_round`:

```
Data Path Delay: 5.777 ns (logic 1.250 ns = 21.6 %, route 4.527 ns = 78.4 %)
Logic Levels: 4 (LUT3=1 LUT4=1 LUT5=1 LUT6=1)
```

Điểm mấu chốt để dự đoán: mỗi mức logic (LUT) trên FPGA luôn kéo
theo một mạng định tuyến ra khỏi nó trước khi tới mức kế — độ trễ
route không phải là "chi phí cố định" tách rời khỏi độ sâu logic, mà
**tích lũy theo từng mức**, vì cấu trúc vật lý (S-box song song 64
làn, các mạng fanout rộng như `fo=250`/`fo=28` do lớp tuyến tính XOR-
xoay) lặp lại giống hệt ở vòng thứ hai. Do đó dự đoán chính: khi nối
thêm một `ascon_round` tổ hợp thứ hai, **cả độ sâu logic (4→~8 mức)
lẫn độ trễ route đều xấp xỉ nhân đôi theo cùng tỉ lệ**, chứ tỉ lệ
logic/route (~22 %/~78 %) được dự đoán **giữ nguyên xấp xỉ**, không
nghiêng hẳn về logic dù logic tăng gấp đôi.

- **Dự đoán trung tâm**: data path delay đường tới hạn mới ≈
  2 × 5.777 ≈ **11.5 ns**, cộng biên margin/skew tương tự → chu kỳ
  khả thi ngắn nhất khoảng **11–12 ns** → **Fmax dự đoán ≈ 85–95 MHz**
  (khoảng rộng hơn 75–115 MHz nếu công cụ place/route tận dụng được
  việc hai `ascon_round` giờ nằm trong cùng một khối tổ hợp không bị
  ngắt bởi thanh ghi, có thể đặt gần nhau hơn và giảm route delay so
  với dự đoán tuyến tính).
- Đây là dự đoán **giảm gần một nửa Fmax**, khác với suy luận ngây
  thơ "route delay đã chiếm 78 %, chỉ logic tăng nên Fmax gần như
  không đổi" — suy luận đó sai vì bỏ qua việc route delay gắn liền
  với số mức logic, không phải hằng số của thiết kế.

### 6.5. Dự đoán thông lượng — câu hỏi mở chính

Đây là phép đánh đổi cần thực nghiệm mới trả lời được, vì hai hiệu
ứng ngược chiều gần triệt tiêu nhau:

- Số chu kỳ/khối giảm còn 5/9 ≈ 0.56 lần (mục 6.2) → xu hướng **tăng**
  thông lượng ~1.8×.
- Fmax dự đoán giảm còn ~85–95/179.73 ≈ 0.47–0.53 lần (mục 6.4) → xu
  hướng **giảm** thông lượng gần 2×.

`throughput_asymptotic_Mbps = Fmax_MHz × 128 / cycles_per_block`:

| | RPC=1 (đo được) | RPC=2 (dự đoán, Fmax=85–95 MHz) |
|---|---|---|
| `cycles_per_block` | 9 | 5 |
| `Fmax_MHz` | 179.73 | 85–95 |
| `throughput_asymptotic_Mbps` | 2556.16 | **2176–2432** (dự đoán **thấp hơn** RPC=1) |
| `Mbps_per_LUT` (÷ `LUT_total` dự đoán 2500–2850) | 1.6428 | **~0.76–0.97** (dự đoán rõ ràng thấp hơn) |

**Dự đoán chính của mục này**: `ROUNDS_PER_CYCLE=2` nhiều khả năng
**không** tăng thông lượng tuyệt đối (thậm chí giảm nhẹ), và chắc
chắn làm giảm hiệu suất diện tích (`Mbps_per_LUT`) so với RPC=1 —
trái ngược trực giác "chạy 2 vòng/chu kỳ thì nhanh hơn". Nếu số đo
thật cho Fmax cao hơn ~113 MHz (129.73×9/5×... cụ thể: Fmax hòa vốn
= 179.73×5/9 ≈ **99.85 MHz**), thông lượng tuyệt đối mới thắng RPC=1;
thấp hơn ngưỡng đó thì RPC=2 vừa tốn thêm LUT vừa chậm hơn về thông
lượng tuyệt đối. **99.85 MHz là ngưỡng hòa vốn cần theo dõi khi đọc
kết quả `make report` thật.**

### 6.6. So sánh với số đo thật (sau `make impl`/`make report` RPC=2)

Số đo thật, từ bộ artifact cuối cùng — tái tạo được, không ghi đè lẫn
nhau (`reports/ppa.csv` dòng `1rpcc`/`2rpcc`,
`reports/timing_critical_rpc1.rpt`, `reports/timing_critical_rpc2.rpt`,
`reports/report_utilization_route_hierarchical_rpc1.rpt`,
`reports/report_utilization_route_hierarchical_rpc2.rpt`):

| | RPC=1 (`*_rpc1.*`) | RPC=2 (`*_rpc2.*`) |
|---|---|---|
| Chu kỳ đã chọn / WNS | 5.600 ns / 0.036 ns | 6.000 ns / 0.143 ns |
| `Fmax` | 179.73 MHz | 170.74 MHz |
| Data path delay đường tới hạn | 5.282 ns (logic 1.260 ns = 23.85 %, route 4.022 ns = 76.15 %) | 5.880 ns (logic 1.262 ns = 21.46 %, route 4.618 ns = 78.54 %) |
| Mức logic đường tới hạn | 3 (LUT2=1 LUT5=1 LUT6=1) | 6 (LUT3=2 LUT5=3 LUT6=1) |

So với dự đoán ở mục 6.4/6.5 (dự đoán dùng baseline dò thử 4 mức/
5.777 ns, khác baseline cuối cùng 3 mức/5.282 ns ở trên — xem ghi chú
đầu mục 6 và 6.4):

| | Dự đoán (mục 6.4/6.5) | Đo thật | Nhận xét |
|---|---|---|---|
| `Fmax` | 85–95 MHz (rộng 75–115) | **170.74 MHz** | Sai nặng — thực tế gần bằng RPC=1 (179.73 MHz), chỉ giảm **5.0 %** |
| Mức logic đường tới hạn | ~8 (nhân đôi từ baseline dò thử 4) | **6** (so với baseline **cuối cùng** 3 → đúng **gấp đôi**, 3→6) | Nhân đôi *đúng* nếu so với baseline cuối cùng — dự đoán chỉ lệch vì dùng nhầm baseline dò thử (4, không phải 3) |
| Data path delay | ~11.5 ns (dự đoán trung tâm, = 2×5.777) | **5.880 ns** (so với RPC=1 cuối cùng 5.282 ns → chỉ tăng **11.3 %**) | Sai nặng dù mức logic tăng đúng gấp đôi — vì độ trễ trung bình mỗi mức **giảm gần một nửa** (1.76 ns/mức ở RPC=1 → 0.98 ns/mức ở RPC=2), không phải hằng số như mô hình dự đoán giả định |
| Tỉ lệ logic/route | dự đoán **giữ nguyên** ~22 %/78 % (so baseline dò thử 21.6/78.4) | **21.5 % / 78.5 %** so baseline dò thử, **21.46 % / 78.54 %** so baseline cuối cùng (23.85 %/76.15 %) | Đúng theo baseline dò thử; so baseline cuối cùng thì phần route còn **tăng nhẹ** (76.15→78.54 %) chứ không hằng định tuyệt đối — nhưng vẫn cùng bậc độ lớn (~1/4–1/5 logic so route ở cả hai) |
| `LUT_core`/`LUT_total` | +70–90 % (≈2400–2850) | **2195 / 2313** (+52.7 %/+48.7 %) | Đúng chiều, sai độ lớn — tăng ít hơn dự đoán |
| `FF_core`/`FF_total` | không đổi | **731 / 1516** (~không đổi) | Đúng |
| `cycles_per_block` | 5 (đúng công thức mục 6.2) | 5 | Đúng — đây là phần cấu trúc thuần túy, không phụ thuộc timing |
| `throughput_asymptotic_Mbps` | 2176–2432 (dự đoán **thấp hơn** RPC=1) | **4370.94** (**cao hơn** RPC=1 71 %) | Sai chiều — dự đoán bi quan quá mức vì dựa trên Fmax sai |
| `Mbps_per_LUT` | ~0.76–0.97 (dự đoán rõ ràng **thấp hơn**) | **1.8897** (**cao hơn** RPC=1 15 %) | Sai chiều — RPC=2 thắng cả thông lượng lẫn hiệu suất diện tích |

**Vì sao Fmax không giảm gần một nửa như dự đoán, dù mức logic đúng
là nhân đôi:**

Đường tới hạn RPC=2 (`u_fsm/u_perm/busy_r_reg/C` →
`u_fsm/u_perm/state_reg[129]/D`, trong `timing_critical_rpc2.rpt`) đi
qua: `busy_r` → `done_r_i_3` (mux tính `perm_start`) → `eff_idx[2]` →
`g_double_round.u_round0/s1[2]` (một phần lớp tuyến tính của **vòng
thứ nhất**) → `g_double_round.m1[2]` (đầu vào vòng thứ hai) →
`g_double_round.u_round1/s2[2]` (lớp phi tuyến của **vòng thứ hai**)
→ mux ghi thanh ghi trạng thái — 6 mức. Đường tới hạn RPC=1
(`u_fsm/state_reg[2]_rep/C` → `u_fsm/u_perm/state_reg[313]/CE`,
trong `timing_critical_rpc1.rpt`) đi qua `round_idx_reg` →
`perm_load` → mux nạp `state[319]` — 3 mức. Đúng bằng một nửa, khớp
chính xác giả thuyết "nối thêm một `ascon_round` thứ hai làm mức logic
tăng gấp đôi" ở mục 6.4.

Nhưng **độ trễ không nhân đôi theo mức logic**: 3 mức của RPC=1 tốn
5.282 ns (≈1.76 ns/mức), còn 6 mức của RPC=2 chỉ tốn 5.880 ns
(≈0.98 ns/mức) — trung bình mỗi mức rẻ đi gần một nửa. Nguyên nhân:
đây không phải "nối 2 khối đen `ascon_round` giống hệt nhau nối
tiếp" như mô hình dự đoán hình dung, mà đường tới hạn mới xuất phát
từ một tổ hợp *khác* (mux điều khiển `perm_start`/`eff_idx`, không
phải xuất phát từ chân `state_reg` như đường tới hạn RPC=1), và báo
cáo utilization ghi chú rõ "cross-hierarchy LUT combining" — công cụ
tổng hợp gộp/tối ưu logic xuyên qua ranh giới hai instance
`ascon_round` thay vì giữ nguyên chúng như hai khối đen tách biệt.
Kết quả: số mức logic tăng đúng như dự đoán cấu trúc (gấp đôi), nhưng
**loại** logic cụ thể trên đường tới hạn mới rẻ hơn (ít fanout rộng
hơn) nên tổng độ trễ gần như không đổi.

**Phần dự đoán đúng — tỉ lệ logic/route cùng bậc độ lớn**: giả thuyết
"mỗi mức logic FPGA luôn kéo theo route, nên route vẫn chiếm phần lớn
đường tới hạn dù độ sâu logic tăng" được xác nhận về **bậc độ lớn**
(cả hai kiến trúc: route ≈ 76–79 %, logic ≈ 21–24 %), dù không giữ
nguyên tuyệt đối (giảm nhẹ phần logic, tăng nhẹ phần route so RPC=1).
Đây là lý do cốt lõi khiến việc nhân đôi *mức* logic không kéo theo
nhân đôi *độ trễ*: phần lớn độ trễ vẫn nằm ở route, và route của
đường tới hạn mới không tăng tỉ lệ thuận với số mức logic mới thêm
vào.

**Kết luận thực nghiệm** (ngược với dự đoán bi quan ở mục 6.5):
`ROUNDS_PER_CYCLE=2` **thắng tuyệt đối** RPC=1 trên cả hai trục —
thông lượng bất đối xứng cao hơn 71 % (4370.94 so với 2556.16 Mbps)
**và** hiệu suất diện tích cao hơn 15 % (1.8897 so với 1.6428
Mbps/LUT) — vì Fmax chỉ giảm 5 % (không phải ~50 % như dự đoán) trong
khi số chu kỳ/khối giảm đúng 44 % (5/9) như dự đoán cấu trúc thuần
túy ở mục 6.2. Ngưỡng hòa vốn 99.85 MHz nêu ở mục 6.5 bị vượt xa (Fmax
thật cao hơn ngưỡng đó 71 %). Bài học: với thiết kế mà đường tới hạn
đã route-dominated (~76–78 % route ngay ở RPC=1), việc nhân đôi logic
tổ hợp trong `generate` **có thể** nhân đôi đúng số mức logic trên
đường tới hạn (đã xảy ra ở đây, 3→6) mà **vẫn không** nhân đôi độ trễ
thật — vì route của FPGA phụ thuộc vào loại tín hiệu/mức fanout cụ
thể trên từng đường đi, không phải hằng số nhân theo số mức logic.

*(Số liệu RPC=1 ở mục 6.6 — 179.73 MHz, chu kỳ 5.6 ns, đường tới hạn
3 mức logic route-dominated — là kết quả đo bằng lưới chu kỳ thô ban
đầu, trước khi `scripts/sweep_fmax.tcl` được viết lại thành quy trình
hai giai đoạn thô/mịn có lưới 0.1 ns nhất quán giữa các kiến trúc.
Lưới mới đo lại RPC=1 cho kết quả chính xác hơn — 182.25 MHz, chu kỳ
5.5 ns — và phát hiện đường tới hạn thật ở mức chu kỳ này KHÔNG phải
đường tới hạn round-datapath nói trên nữa, mà là một đường hoàn toàn
khác. Xem mục 7 để có số liệu và phân tích cập nhật, nhất quán giữa
cả ba kiến trúc `ROUNDS_PER_CYCLE=1/2/4`.)*

---

## 7. Ba điểm dữ liệu Pareto: `ROUNDS_PER_CYCLE` ∈ {1, 2, 4}

Mục này ứng với bước 9 quy trình làm việc ("bảng PPA và biểu đồ
Pareto"). Số liệu lấy từ `reports/ppa.csv` (ba dòng `1rpcc`/`2rpcc`/
`4rpcc`) và `reports/timing_critical_rpc{1,2,4}.rpt`, đo bằng cùng
một quy trình quét Fmax hai giai đoạn (thô ước lượng sau `place_design`
để khoanh vùng, mịn có `phys_opt_design`+`route_design` trên lưới chu
kỳ bội số 0.1 ns để ba kiến trúc nhất quán) trong `scripts/sweep_fmax.tcl`.

### 7.1. Bảng PPA ba điểm

| | RPC=1 | RPC=2 | RPC=4 |
|---|---|---|---|
| Chu kỳ đã chọn / WNS | 5.5 ns / 0.013 ns | 6.0 ns / 0.143 ns | 11.2 ns / 0.060 ns |
| `Fmax` | 182.25 MHz | 170.74 MHz | 89.77 MHz |
| `LUT_core` / `LUT_total` | 1437 / 1555 | 2195 / 2313 | 3447 / 3565 |
| `FF_core` / `FF_total` | 732 / 1517 | 731 / 1516 | 730 / 1515 |
| `cycles_per_block` | 9 | 5 | 3 |
| `throughput_asymptotic_Mbps` | 2592.00 | 4370.94 | 3830.19 |
| `throughput_16B_packet_Mbps` | 613.89 | 993.40 | 820.75 |
| `Mbps_per_LUT` | 1.6669 | 1.8897 | 1.0743 |

### 7.2. Xu hướng `Mbps/LUT` — tăng rồi **đảo chiều giảm**, không phải bão hòa

```
RPC=1 -> RPC=2:  1.6669 -> 1.8897   (+13.4 %)
RPC=2 -> RPC=4:  1.8897 -> 1.0743   (-43.2 %)
RPC=1 -> RPC=4:  1.6669 -> 1.0743   (-35.5 %, THAP HON CA RPC=1)
```

Đây **không phải hiện tượng bão hòa** (đường cong phẳng dần) mà là
**đảo chiều thật sự**: RPC=4 không chỉ tăng chậm lại, nó tệ hơn cả
điểm khởi đầu RPC=1. Cơ chế: `cycles_per_block` giảm đều đặn theo cấp
số nhân ngược (9→5→3, tức ×0.56 rồi ×0.6), nhưng `LUT_total` tăng
nhanh hơn tuyến tính ở bước RPC=2→4 (+54.1 %, so với +48.7 % ở bước
RPC=1→2) **trong khi Fmax sụp mạnh** (−47.4 % so với chỉ −6.3 % ở bước
trước) — logic tổ hợp bốn `ascon_round` nối tiếp (11 mức logic, mục
7.3) vừa tốn nhiều LUT hơn tuyến tính vừa kéo Fmax xuống gần một nửa,
áp đảo hoàn toàn phần lợi từ số chu kỳ/khối thấp hơn. Thông lượng
tuyệt đối cũng vậy: RPC=4 (3830.19 Mbps) thấp hơn RPC=2 (4370.94 Mbps)
dù vẫn cao hơn RPC=1 — nghĩa là **RPC=2 là điểm tối ưu Pareto** trong
ba điểm đã đo, không phải RPC=4. Nếu mục tiêu là thông lượng/diện
tích, tăng `ROUNDS_PER_CYCLE` quá điểm này phản tác dụng với thiết kế
này trên `xc7a35tcpg236-1`.

### 7.3. Tỉ lệ logic/route — dịch chuyển dần, và một bất ngờ ở RPC=1

Đường tới hạn RPC=2 và RPC=4 (đo được ở lưới cuối) đều cùng **loại**
— xuất phát từ vùng điều khiển/mux nạp thanh ghi trạng thái, đi qua
chuỗi `ascon_round` nối tiếp (mục 6.6 đã mô tả cơ chế này cho RPC=2):

| | RPC=2 (6.0 ns) | RPC=4 (11.2 ns) |
|---|---|---|
| Mức logic | 6 | 11 |
| Logic | 1.262 ns (21.46 %) | 1.820 ns (16.42 %) |
| Route | 4.618 ns (78.54 %) | 9.262 ns (83.58 %) |

Xu hướng nhất quán: **route càng chiếm ưu thế hơn khi RPC càng lớn**
(78.5 %→83.6 %, logic 21.5 %→16.4 %) — hợp lý, vì chuỗi tổ hợp càng
dài càng phải băng qua khoảng cách vật lý lớn hơn trên die, trong khi
mỗi mức logic (LUT) tự thân không đổi nhiều về độ trễ.

**Nhưng RPC=1 không nối tiếp được xu hướng này** — đường tới hạn thật
ở chu kỳ 5.5 ns (`reports/timing_critical_rpc1.rpt`) **không phải**
đường round-datapath nói trên nữa, mà là một chuỗi hoàn toàn khác:

```
Source:      tag_in_r_reg[22]/C
Destination: u_fsm/dout_r_reg[104]/CE
Data Path Delay: 5.211 ns (logic 2.558 ns = 49.09 %, route 2.653 ns = 50.91 %)
Logic Levels: 13 (CARRY4=10 LUT4=1 LUT6=2)
```

Đây chính là chuỗi `CARRY4` từng ghi trong `docs/BUGS.md`/commit
"Rewrite byte-mask logic as case: -258 LUT; investigate CARRY4 chain"
— sinh ra từ phép so sánh 128-bit `tag`/`tag_in` tương tác với logic
byte-mask trong `ascon_aead_fsm`. Ở chu kỳ thoải mái hơn (5.6–6.0 ns),
đường round-datapath (mục 6.4/6.6) vẫn là nút thắt; nhưng khi ép chu
kỳ xuống tới giới hạn thật của RPC=1 (5.5 ns), round-datapath của RPC=1
(chỉ 1 `ascon_round`, rất ngắn) đã đủ nhanh để **nhường vị trí nút
thắt cho chuỗi CARRY4**, vốn gần như không đổi theo `ROUNDS_PER_CYCLE`
(không nằm trong `ascon_perm`). Vì CARRY4 trong cùng cột slice có độ
trễ định tuyến giữa các tầng gần như bằng 0, tỉ lệ logic/route của
đường này cân bằng (49/51 %) — khác hẳn kiểu route-dominated (~78–84 %)
của round-datapath ở RPC=2/4.

**Hệ quả cho khảo sát kiến trúc**: trần Fmax của RPC=1 do một nút thắt
*ngoài* `ascon_perm` quyết định (chuỗi so sánh tag/byte-mask trong
FSM), trong khi trần Fmax của RPC=2 và RPC=4 do chính `ascon_perm`
quyết định (round-datapath). Nói cách khác, nếu tiếp tục khảo sát các
điểm `ROUNDS_PER_CYCLE` khác trong tương lai, chuỗi CARRY4 này là một
ứng viên nút thắt tiềm ẩn cần theo dõi lại một khi round-datapath được
rút ngắn đủ nhiều (ví dụ nếu sau này tối ưu lại `ascon_round`) — nó
chưa từng được tối ưu vì trước nay luôn bị round-datapath che khuất.
