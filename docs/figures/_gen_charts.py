# Sinh nhóm 1: bốn biểu đồ số liệu (matplotlib), PNG 300 DPI, nền trắng.
import csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 11,
    "axes.edgecolor": "#333333",
    "axes.labelcolor": "#111111",
    "text.color": "#111111",
    "xtick.color": "#111111",
    "ytick.color": "#111111",
    "figure.facecolor": "white",
    "axes.facecolor": "white",
    "savefig.facecolor": "white",
    "axes.grid": True,
    "grid.alpha": 0.25,
    "grid.linewidth": 0.6,
    "axes.spines.top": False,
    "axes.spines.right": False,
})

OUT = "E:/Project_FPGA/DACN/docs/figures"
DPI = 300
GRAY = "#404040"
ACCENT = "#2b5b84"

def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

# ---------------------------------------------------------------
# 1. pareto_area_throughput.png
# ---------------------------------------------------------------
rows = read_csv("E:/Project_FPGA/DACN/reports/ppa.csv")
pts = {r["architecture"]: (float(r["throughput_asymptotic_Mbps"]), float(r["LUT_total"])) for r in rows}
order = ["1rpcc", "2rpcc", "4rpcc"]
label_map = {"1rpcc": "RPC=1", "2rpcc": "RPC=2", "4rpcc": "RPC=4"}

fig, ax = plt.subplots(figsize=(7.0, 5.4))
xs = [pts[k][0] for k in order]
ys = [pts[k][1] for k in order]
ax.scatter(xs, ys, s=70, color=ACCENT, zorder=3)

offsets = {
    "1rpcc": (-14, -26),
    "2rpcc": (12, -8),
    "4rpcc": (-95, -8),
}
for k in order:
    x, y = pts[k]
    dx, dy = offsets[k]
    ax.annotate(label_map[k], xy=(x, y), textcoords="offset points",
                xytext=(dx, dy), fontsize=11, color="#111111")

# Đường biên Pareto: RPC=1 và RPC=2 không bị điểm nào lấn át
# (thông lượng cao hơn VÀ LUT thấp hơn); RPC=4 bị RPC=2 lấn át hoàn toàn.
frontier = ["1rpcc", "2rpcc"]
fx = [pts[k][0] for k in frontier]
fy = [pts[k][1] for k in frontier]
ax.plot(fx, fy, color=GRAY, linewidth=1.6, linestyle="--", zorder=2, label="Biên Pareto")

ax.set_xlim(min(xs) - 350, max(xs) + 350)
ax.set_ylim(min(ys) - 250, max(ys) + 450)
ax.set_xlabel("Thông lượng tiệm cận (Mbps)")
ax.set_ylabel("LUT tổng (LUT_total)")
ax.set_title("Diện tích so với thông lượng — ba điểm ROUNDS_PER_CYCLE", pad=14)
ax.legend(loc="lower right", frameon=False)
fig.tight_layout()
fig.savefig(f"{OUT}/pareto_area_throughput.png", dpi=DPI)
plt.close(fig)

# ---------------------------------------------------------------
# 2. efficiency_vs_unroll.png
# ---------------------------------------------------------------
eff = {r["architecture"]: float(r["Mbps_per_LUT"]) for r in rows}
labels = ["1", "2", "4"]
values = [eff["1rpcc"], eff["2rpcc"], eff["4rpcc"]]
colors = [ACCENT, "#1f7a3f", ACCENT]

fig, ax = plt.subplots(figsize=(6.8, 4.6))
bars = ax.bar(labels, values, color=colors, width=0.55, zorder=3)
for rect, v in zip(bars, values):
    ax.annotate(f"{v:.3f}", (rect.get_x() + rect.get_width() / 2, v),
                xytext=(0, 4), textcoords="offset points",
                ha="center", fontsize=11)
bars[1].set_edgecolor("#0d3d1f")
bars[1].set_linewidth(1.6)
ax.annotate("tối ưu", xy=(1, values[1]), xytext=(0, 24), textcoords="offset points",
            ha="center", fontsize=10.5, color="#1f7a3f")

ax.set_xlabel("Số vòng hoán vị mỗi chu kỳ (ROUNDS_PER_CYCLE)")
ax.set_ylabel("Hiệu suất diện tích (Mbps/LUT)")
ax.set_title("Hiệu suất diện tích theo mức xử lý song song vòng hoán vị")
ax.set_ylim(0, max(values) * 1.25)
fig.tight_layout()
fig.savefig(f"{OUT}/efficiency_vs_unroll.png", dpi=DPI)
plt.close(fig)

# ---------------------------------------------------------------
# 3. multidevice_fmax.png
# ---------------------------------------------------------------
md_rows = read_csv("E:/Project_FPGA/DACN/reports/ppa_multidevice.csv")
dev_labels = [f"{r['family']}" for r in md_rows]
fmax = [float(r["Fmax_MHz"]) for r in md_rows]
speed = [r["speed_grade"] for r in md_rows]

fig, ax = plt.subplots(figsize=(6.4, 4.6))
bars = ax.bar(dev_labels, fmax, color=[ACCENT, "#1f7a3f", "#8a4b2b"], width=0.55, zorder=3)
for rect, v, sg in zip(bars, fmax, speed):
    ax.annotate(f"{v:.2f} MHz", (rect.get_x() + rect.get_width() / 2, v),
                xytext=(0, 4), textcoords="offset points", ha="center", fontsize=11)
    ax.annotate(f"speed grade {sg}", (rect.get_x() + rect.get_width() / 2, 0),
                xytext=(0, 8), textcoords="offset points", ha="center", fontsize=9.5,
                color="#444444")

ax.set_xlabel("Dòng chip (ROUNDS_PER_CYCLE = 1)")
ax.set_ylabel("Fmax (MHz)")
ax.set_title("Fmax trên ba dòng FPGA Xilinx 7-series")
ax.set_ylim(0, max(fmax) * 1.2)
fig.tight_layout()
fig.savefig(f"{OUT}/multidevice_fmax.png", dpi=DPI)
plt.close(fig)

# ---------------------------------------------------------------
# 4. comparison_area_throughput.png
# ---------------------------------------------------------------
# Bảng Artix-7 từ docs/comparison.md mục 2 (LUT, Throughput Mbps)
comp = [
    ("Đồ án này\n(Ascon-AEAD128, rate 128, p8)", 1555, 2592.00, ACCENT, "o"),
    ("Alharbi 2024\n(Ascon-128 v1.2, rate 64, p6)", 1756, 376, "#8a4b2b", "s"),
    ("Malal — ASCON-128\n(v1.2, rate 64, p6)", 2957, 3535.91, "#7a1f7a", "^"),
    ("Malal — ASCON-128a\n(v1.2, rate 128, p8)", 2183, 5333.30, "#1f7a3f", "D"),
]

fig, ax = plt.subplots(figsize=(8.6, 6.2))
label_offsets = [
    (14, -30),
    (14, 10),
    (-90, -34),
    (-125, 16),
]
for (name, lut, thr, color, marker), (dx, dy) in zip(comp, label_offsets):
    ax.scatter(thr, lut, s=90, color=color, marker=marker, zorder=3)
    ax.annotate(name, xy=(thr, lut), textcoords="offset points", xytext=(dx, dy), fontsize=9.5)

xs_c = [c[2] for c in comp]
ys_c = [c[1] for c in comp]
ax.set_xlim(min(xs_c) - 500, max(xs_c) + 500)
ax.set_ylim(min(ys_c) - 250, max(ys_c) + 400)
ax.set_xlabel("Thông lượng (Mbps)")
ax.set_ylabel("LUT")
ax.set_title("So sánh diện tích–thông lượng trên Artix-7 với công trình liên quan", pad=14)
fig.tight_layout()
fig.savefig(f"{OUT}/comparison_area_throughput.png", dpi=DPI)
plt.close(fig)

print("done group 1")
