# Sinh nhóm 2: bốn sơ đồ khối, vẽ trực tiếp bằng matplotlib patches
# (hộp bo góc + mũi tên) thay vì SVG->PNG, vì máy này không có
# cairosvg (thiếu thư viện cairo gốc) lẫn Inkscape. Cách này cho ra
# cùng phong cách hình ảnh (nền trắng, hộp chữ nhật bo góc, mũi tên,
# không đổ bóng) và giữ nhất quán font chữ tiếng Việt (DejaVu Sans)
# với nhóm biểu đồ số liệu.
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle
from matplotlib.path import Path

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 11,
    "text.color": "#111111",
    "figure.facecolor": "white",
    "savefig.facecolor": "white",
})

OUT = "E:/Project_FPGA/DACN/docs/figures"
DPI = 300

BOX_FC = "#eef3f8"
BOX_EC = "#2b5b84"
BOX_FC2 = "#eef7ee"
BOX_EC2 = "#1f7a3f"
ARROW_C = "#333333"
DASH_C = "#666666"


def new_ax(w, h, figsize):
    fig, ax = plt.subplots(figsize=figsize)
    ax.set_xlim(0, w)
    ax.set_ylim(0, h)
    ax.set_aspect("equal")
    ax.axis("off")
    return fig, ax


def box(ax, x, y, w, h, text, fc=BOX_FC, ec=BOX_EC, fontsize=11, lw=1.4,
        style="round,pad=0.02,rounding_size=0.18", dashed=False, zorder=3):
    patch = FancyBboxPatch((x, y), w, h, boxstyle=style,
                            linewidth=lw, edgecolor=ec, facecolor=fc,
                            linestyle="dashed" if dashed else "solid",
                            zorder=zorder)
    ax.add_patch(patch)
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
             fontsize=fontsize, zorder=zorder + 1, linespacing=1.35)
    return patch


def arrow(ax, p_from, p_to, text=None, color=ARROW_C, lw=1.5,
          connectionstyle="arc3,rad=0.0", text_offset=(0, 0.14),
          fontsize=9.5, ls="-", text_color="#111111"):
    a = FancyArrowPatch(p_from, p_to, arrowstyle="-|>", mutation_scale=14,
                         linewidth=lw, color=color, shrinkA=1, shrinkB=1,
                         connectionstyle=connectionstyle, linestyle=ls, zorder=2)
    ax.add_patch(a)
    if text:
        mx = (p_from[0] + p_to[0]) / 2 + text_offset[0]
        my = (p_from[1] + p_to[1]) / 2 + text_offset[1]
        ax.text(mx, my, text, ha="center", va="center", fontsize=fontsize,
                color=text_color, zorder=4,
                bbox=dict(boxstyle="round,pad=0.12", fc="white", ec="none"))


# =================================================================
# 1. block_diagram.png — sơ đồ khối hệ thống
# =================================================================
fig, ax = new_ax(12, 6, (9.5, 5.0))

box(ax, 0.6, 2.3, 2.6, 1.6, "Vi xử lý\n(CPU / SoC)", fontsize=12)

# Bus APB — hình chữ nhật dẹt biểu diễn bus, có mũi tên hai chiều
bus_y0, bus_y1 = 2.75, 3.05
ax.add_patch(Rectangle((3.2, bus_y0), 2.2, bus_y1 - bus_y0,
                        facecolor="#dddddd", edgecolor="#555555", linewidth=1.2, zorder=2))
ax.text(4.3, bus_y1 + 0.28, "Bus AMBA APB", ha="center", fontsize=10.5)
arrow(ax, (3.2, 2.9), (2.6, 2.9), color="#555555", lw=1.2)
arrow(ax, (5.4, 2.9), (6.0, 2.9), color="#555555", lw=1.2)

# Lõi IP — khung ngoài nét đứt
box(ax, 6.0, 0.5, 5.4, 5.0, "", fc="none", ec=DASH_C, dashed=True, lw=1.3)
ax.text(8.7, 5.25, "Lõi IP Ascon-AEAD128", ha="center", fontsize=12, weight="bold")

box(ax, 6.5, 3.7, 4.4, 1.2, "APB slave\n(rtl/ip/ascon_apb.v)",
    fc=BOX_FC, ec=BOX_EC, fontsize=11)
box(ax, 6.5, 2.0, 4.4, 1.2, "ascon_aead_fsm\n(điều khiển AEAD)",
    fc=BOX_FC, ec=BOX_EC, fontsize=11)
box(ax, 6.5, 0.75, 4.4, 0.95, "ascon_perm\n(p12 / p8)",
    fc=BOX_FC2, ec=BOX_EC2, fontsize=11)

arrow(ax, (8.7, 3.7), (8.7, 3.2))
arrow(ax, (8.7, 2.0), (8.7, 1.7))

fig.tight_layout()
fig.savefig(f"{OUT}/block_diagram.png", dpi=DPI)
plt.close(fig)

# =================================================================
# 2. datapath.png — datapath kiến trúc một vòng mỗi chu kỳ
# =================================================================
fig, ax = new_ax(13, 10, (9.5, 7.3))

# Bộ đếm vòng (trên cùng, trái) -> tra RC
box(ax, 0.5, 8.4, 2.4, 1.0, "Bộ đếm vòng\nround_idx[3:0]", fontsize=10)
box(ax, 3.4, 8.4, 2.6, 1.0, "case(round_idx)\ntra hằng số RC", fontsize=10)
arrow(ax, (2.9, 8.9), (3.4, 8.9))

# ascon_round tổ hợp (trung tâm)
box(ax, 3.0, 5.6, 4.4, 2.2,
    "ascon_round (tổ hợp)\nx2 ^= RC\nascon_sbox (phi tuyến)\nascon_linear (xoay-XOR)",
    fc=BOX_FC2, ec=BOX_EC2, fontsize=10.5)
arrow(ax, (4.6, 8.4), (4.6, 7.8), text="RC")

# Thanh ghi trạng thái 320-bit (trung tâm dưới)
box(ax, 3.0, 1.6, 4.4, 1.6, "Thanh ghi trạng thái 320 bit\nS0 | S1 | S2 | S3 | S4",
    fc=BOX_FC, ec=BOX_EC, fontsize=11)

# MUX ghi thanh ghi trạng thái
box(ax, 3.0, 3.5, 4.4, 1.2,
    "MUX ghi state_in\n(vòng kế tiếp | XOR dữ liệu |\nXOR khóa | nạp IV||K||N)",
    fc="#f5f0e6", ec="#8a6d1f", fontsize=9.5)
arrow(ax, (5.2, 5.6), (5.2, 4.7))
arrow(ax, (5.2, 3.5), (5.2, 3.2))

# Đường phản hồi: state -> vào ascon_round (đường vòng bên trái)
arrow(ax, (3.0, 2.4), (0.9, 2.4), color=ARROW_C, lw=1.3,
      connectionstyle="arc3,rad=0.0")
arrow(ax, (0.9, 2.4), (0.9, 6.7), color=ARROW_C, lw=1.3,
      connectionstyle="arc3,rad=0.0")
arrow(ax, (0.9, 6.7), (3.0, 6.7), color=ARROW_C, lw=1.3,
      connectionstyle="arc3,rad=0.0", text="đường phản hồi (feedback)",
      text_offset=(0.05, 0.35), fontsize=9)

# XOR dữ liệu vào rate (bên phải, giữa)
box(ax, 8.5, 5.9, 4.0, 1.5,
    "XOR dữ liệu vào rate\ndin[127:0] -> S0/S1\n(+bit phân tách miền S4\nnếu là PROC_TEXT đầu)",
    fc="#f5e6ee", ec="#8a1f5b", fontsize=9.3)
arrow(ax, (8.5, 6.6), (7.4, 6.6), text="din")
arrow(ax, (9.7, 5.9), (7.4, 4.1), connectionstyle="arc3,rad=-0.18")

# Đầu ra bản mã/bản rõ (bên phải, dưới)
box(ax, 8.5, 1.7, 4.0, 1.6,
    "Mã hóa: dout = rate mới\nGiải mã: dout = rate cũ ^ din\n(qua mask valid_bytes\nnếu khối cuối)",
    fc=BOX_FC, ec=BOX_EC, fontsize=9.5)
arrow(ax, (7.4, 2.4), (8.5, 2.5), text="S0/S1")
ax.annotate("", xy=(12.6, 2.5), xytext=(12.5, 2.5),
            arrowprops=dict(arrowstyle="-|>", color=ARROW_C, lw=1.5))
arrow(ax, (12.5, 2.5), (12.9, 2.5))
ax.text(12.95, 2.5, "dout[127:0]\n(-> DOUT0..3)", ha="left", va="center", fontsize=9.5)

ax.set_xlim(0, 15.2)
fig.tight_layout()
fig.savefig(f"{OUT}/datapath.png", dpi=DPI)
plt.close(fig)

# =================================================================
# 3. fsm_diagram.png — máy trạng thái AEAD, 7 trạng thái
# =================================================================
def elbow_arrow(ax, points, color=ARROW_C, lw=1.4):
    codes = [Path.MOVETO] + [Path.LINETO] * (len(points) - 1)
    path = Path(points, codes)
    patch = FancyArrowPatch(path=path, arrowstyle="-|>", mutation_scale=14,
                             linewidth=lw, color=color, zorder=2)
    ax.add_patch(patch)


def label(ax, x, y, text, fontsize=8.6, ha="center", va="center"):
    ax.text(x, y, text, ha=ha, va=va, fontsize=fontsize, color="#111111",
             zorder=4, bbox=dict(boxstyle="round,pad=0.12", fc="white", ec="none"))


def self_loop(ax, x0, x1, y, text, above=True, fontsize=8.6):
    # rad < 0 bulges the arc toward +y (up) for a left-to-right chord;
    # rad > 0 bulges toward -y (down) — verified empirically.
    rad = -0.8 if above else 0.8
    a = FancyArrowPatch((x0, y), (x1, y), arrowstyle="-|>", mutation_scale=13,
                         linewidth=1.4, color=ARROW_C,
                         connectionstyle=f"arc3,rad={rad}", zorder=5)
    ax.add_patch(a)
    ty = y + 1.05 if above else y - 1.05
    label(ax, (x0 + x1) / 2, ty, text, fontsize=fontsize)


fig, ax = new_ax(17.4, 13.4, (12.5, 9.6))

states = {
    "IDLE":        (6.4, 11.4, 3.2, 1.1, "S_IDLE"),
    "LOAD":        (1.1, 8.7, 2.8, 1.1, "S_LOAD"),
    "XOR_IN":      (6.5, 8.7, 2.8, 1.1, "S_XOR_IN"),
    "FIN_KEYXOR":  (12.0, 8.7, 3.2, 1.1, "S_FIN_KEYXOR"),
    "PERM":        (6.3, 5.6, 3.4, 1.3, "S_PERM"),
    "INIT_KEYXOR": (1.0, 2.4, 3.4, 1.1, "S_INIT_KEYXOR"),
    "FIN_TAGXOR":  (11.8, 2.4, 3.6, 1.1, "S_FIN_TAGXOR"),
}
for key, (x, y, w, h, txt) in states.items():
    fc, ec = (BOX_FC2, BOX_EC2) if key == "IDLE" else (BOX_FC, BOX_EC)
    box(ax, x, y, w, h, txt, fc=fc, ec=ec, fontsize=11.5, lw=1.6)

# --- Các cạnh chuyển tiếp trực tiếp (đường thẳng / cong nhẹ) ---

# S_IDLE -> S_LOAD (opcode=INIT)
arrow(ax, (7.0, 11.4), (3.3, 9.8), connectionstyle="arc3,rad=0.12")
label(ax, 4.6, 10.75, "opcode=INIT")

# S_IDLE -> S_XOR_IN (PROC_AD / PROC_TEXT)
arrow(ax, (7.9, 11.4), (7.9, 9.8))
label(ax, 9.3, 10.6, "PROC_AD /\nPROC_TEXT")

# S_IDLE -> S_FIN_KEYXOR (opcode=FINAL)
arrow(ax, (9.0, 11.4), (12.8, 9.8), connectionstyle="arc3,rad=-0.12")
label(ax, 11.7, 10.75, "opcode=FINAL")

# S_IDLE self-loop (NOP / không có start)
self_loop(ax, 6.9, 9.1, 12.5, "NOP / SOFT_RESET /\nkhông có start", above=True)

# S_LOAD -> S_PERM (luôn, round_idx=4)
arrow(ax, (2.6, 8.7), (6.9, 6.7), connectionstyle="arc3,rad=0.1")
label(ax, 3.6, 7.2, "luôn\n(round_idx=4)")

# S_XOR_IN -> S_PERM (PROC_AD hoặc PROC_TEXT không cuối)
arrow(ax, (7.6, 8.7), (7.6, 6.9))
label(ax, 9.4, 7.8, "PROC_AD hoặc PROC_TEXT\nkhông cuối (round_idx=8)")

# S_XOR_IN -> S_IDLE (PROC_TEXT & last=1, bỏ qua p8)
arrow(ax, (6.5, 9.3), (6.4, 11.4), connectionstyle="arc3,rad=-0.45")
label(ax, 4.05, 10.35, "PROC_TEXT & last=1\n(bỏ qua p8, done ngay)")

# S_FIN_KEYXOR -> S_PERM (luôn, round_idx=4)
arrow(ax, (13.0, 8.7), (9.3, 6.7), connectionstyle="arc3,rad=-0.1")
label(ax, 12.0, 7.2, "luôn\n(round_idx=4)")

# S_PERM self-loop (round_idx < 15) — đặt bên phải để tránh giao với
# mũi tên S_XOR_IN -> S_PERM ở cạnh trên
_perm_loop = FancyArrowPatch((9.7, 5.95), (9.7, 6.55), arrowstyle="-|>",
                              mutation_scale=13, linewidth=1.4, color=ARROW_C,
                              connectionstyle="arc3,rad=0.8", zorder=5)
ax.add_patch(_perm_loop)
label(ax, 10.85, 6.25, "round_idx\n< 15")

# S_PERM -> S_INIT_KEYXOR (ret_state=S_INIT_KEYXOR)
arrow(ax, (6.9, 5.6), (3.2, 3.5), connectionstyle="arc3,rad=0.12")
label(ax, 4.1, 4.9, "ret_state=\nS_INIT_KEYXOR")

# S_PERM -> S_FIN_TAGXOR (ret_state=S_FIN_TAGXOR)
arrow(ax, (9.1, 5.6), (13.0, 3.5), connectionstyle="arc3,rad=-0.12")
label(ax, 11.9, 4.9, "ret_state=\nS_FIN_TAGXOR")

# --- Ba cạnh quay về S_IDLE, đi vòng theo hành lang ngoài để không
#     cắt qua các hộp khác (kiểu định tuyến vuông góc sơ đồ mạch) ---

# S_PERM -> S_IDLE (ret_state=S_IDLE: done, khối AD/PT không phải cuối)
elbow_arrow(ax, [(6.3, 6.6), (0.7, 6.6), (0.7, 11.7), (6.4, 11.7)])
label(ax, 0.15, 9.1, "ret_state=S_IDLE\n(done, khối\nkhông cuối)", fontsize=8.2)

# S_INIT_KEYXOR -> S_IDLE (luôn, sau 1 chu kỳ)
elbow_arrow(ax, [(1.0, 2.95), (0.35, 2.95), (0.35, 12.0), (6.4, 12.0)])
label(ax, -0.25, 6.0, "luôn", fontsize=8.6)

# S_FIN_TAGXOR -> S_IDLE (luôn: tag_valid, done, tag_fail nếu mode=1)
elbow_arrow(ax, [(15.4, 2.95), (16.7, 2.95), (16.7, 12.1), (9.6, 12.1)])
label(ax, 17.05, 6.5, "luôn (tag_valid,\ndone, tag_fail\nnếu mode=1)", fontsize=8.2)

ax.set_xlim(-1.0, 17.6)
ax.set_ylim(1.9, 13.9)
fig.tight_layout()
fig.savefig(f"{OUT}/fsm_diagram.png", dpi=DPI)
plt.close(fig)

# =================================================================
# 4. aead_phases.png — bốn giai đoạn Ascon-AEAD128
# =================================================================
fig, ax = new_ax(15, 6.5, (11.0, 4.9))

phase_y, phase_h, phase_w, gap = 2.2, 1.9, 3.0, 0.6
xs = [0.6, 0.6 + (phase_w + gap), 0.6 + 2 * (phase_w + gap), 0.6 + 3 * (phase_w + gap)]
phases = [
    ("Khởi tạo\np12", BOX_FC, BOX_EC),
    ("Xử lý AD\np8 mỗi khối", BOX_FC2, BOX_EC2),
    ("Xử lý bản rõ\np8 mỗi khối\n(trừ khối cuối)", "#f5f0e6", "#8a6d1f"),
    ("Hoàn tất\np12", BOX_FC, BOX_EC),
]
for x, (label, fc, ec) in zip(xs, phases):
    box(ax, x, phase_y, phase_w, phase_h, label, fc=fc, ec=ec, fontsize=11.5)

for i in range(3):
    x0 = xs[i] + phase_w
    x1 = xs[i + 1]
    arrow(ax, (x0, phase_y + phase_h / 2), (x1, phase_y + phase_h / 2), lw=1.8)

# Đầu vào phía trên
arrow(ax, (xs[0] + phase_w / 2, phase_y + phase_h + 0.9), (xs[0] + phase_w / 2, phase_y + phase_h))
ax.text(xs[0] + phase_w / 2, phase_y + phase_h + 1.1, "K, N", ha="center", fontsize=11)

arrow(ax, (xs[1] + phase_w / 2, phase_y + phase_h + 0.9), (xs[1] + phase_w / 2, phase_y + phase_h))
ax.text(xs[1] + phase_w / 2, phase_y + phase_h + 1.1, "A (AD)", ha="center", fontsize=11)

arrow(ax, (xs[2] + phase_w / 2, phase_y + phase_h + 0.9), (xs[2] + phase_w / 2, phase_y + phase_h))
ax.text(xs[2] + phase_w / 2, phase_y + phase_h + 1.1, "P (bản rõ)", ha="center", fontsize=11)

# Đầu ra phía dưới
arrow(ax, (xs[2] + phase_w / 2, phase_y), (xs[2] + phase_w / 2, phase_y - 0.9))
ax.text(xs[2] + phase_w / 2, phase_y - 1.1, "C (bản mã)", ha="center", fontsize=11)

arrow(ax, (xs[3] + phase_w / 2, phase_y), (xs[3] + phase_w / 2, phase_y - 0.9))
ax.text(xs[3] + phase_w / 2, phase_y - 1.1, "T (tag)", ha="center", fontsize=11)

ax.set_xlim(0, 14.6)
ax.set_ylim(0.4, 6.1)
fig.tight_layout()
fig.savefig(f"{OUT}/aead_phases.png", dpi=DPI)
plt.close(fig)

print("done group 2")
