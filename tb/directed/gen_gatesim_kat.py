#!/usr/bin/env python3
"""Extract a 20-vector subset of tb/directed/kat_128_128.hex for gate-
level simulation (buoc 8, xem docs/uarch.md).

Gate-level xsim is tens of times slower than RTL iverilog, so tb_gatesim.v
does not replay all 1089 KAT vectors -- only these 20, chosen by
(AD_len, PT_len) in bytes to hit every category in tb/directed/tb_apb.v's
coverage that also matters for padding correctness (CLAUDE.md "Nhung cho
hay sai" #3/#5/#6):

  - 5x AD rong      (AD_len=0):      Count 1, 34, 496, 529, 1057
  - 5x PT rong      (PT_len=0):      Count 2, 16, 17, 18, 33
  - 5x khoi cuoi le byte (AD_len%16!=0 and PT_len%16!=0, both nonzero):
                                      Count 35, 171, 577, 961, 1041
  - 5x do dai boi so 16 (AD_len and/or PT_len a nonzero multiple of 16,
    exercising the extra all-zero padding block -- rule #3): Count 50,
    545, 561, 1073, 1089

Each vector keeps its original 41-word encoding (same layout tb_apb.v
reads: count, key x2, nonce x2, n_ad, n_pt, ad_len, pt_len, AD blocks
x4x3, PT blocks x4x3, CT blocks x2x3, tag x2) and its original Count
field, unchanged -- only the source file's vector order is filtered, not
re-encoded, so this script cannot introduce a new bug in the KAT data
itself. Re-run after regenerating tb/directed/kat_128_128.hex:

    python tb/directed/gen_gatesim_kat.py
"""

VEC_WORDS = 41
N_VEC = 1089

SELECTED_COUNTS = [
    # AD rong
    1, 34, 496, 529, 1057,
    # PT rong
    2, 16, 17, 18, 33,
    # khoi cuoi le byte (AD va PT deu khac boi so 16, khac 0)
    35, 171, 577, 961, 1041,
    # do dai boi so 16 (co khoi dem phu)
    50, 545, 561, 1073, 1089,
]


def main():
    src = "tb/directed/kat_128_128.hex"
    dst = "tb/directed/kat_gatesim20.hex"

    tokens = open(src).read().split()
    assert len(tokens) == VEC_WORDS * N_VEC, \
        f"{src}: expected {VEC_WORDS * N_VEC} tokens, got {len(tokens)}"
    assert len(SELECTED_COUNTS) == len(set(SELECTED_COUNTS)) == 20

    lines = []
    for count in SELECTED_COUNTS:
        base = (count - 1) * VEC_WORDS
        vec = tokens[base:base + VEC_WORDS]
        assert int(vec[0], 16) == count
        for i in range(0, VEC_WORDS, 8):
            lines.append(" ".join(vec[i:i + 8]))

    with open(dst, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print(f"wrote {dst}: {len(SELECTED_COUNTS)} vectors, "
          f"{len(SELECTED_COUNTS) * VEC_WORDS} words")


if __name__ == "__main__":
    main()
