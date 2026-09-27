#!/usr/bin/env python3
"""Generate tb/directed/long_vectors.hex: random Ascon-AEAD128 vectors with
messages far longer than the NIST KAT (which stops at 32 bytes), for
tb/directed/tb_long.v.

Expected ciphertext/tag come from model/ascon_model.py (the golden model,
itself checked against the NIST KAT). Fixed seed -> the file is
reproducible; regenerate with:

    python tb/directed/gen_long_vectors.py

Format ($readmemh, one 64-bit word per line):
  word 0: number of vectors
  per vector:
    key_lo key_hi nonce_lo nonce_hi n_ad n_pt
    n_ad x (lo hi last valid_bytes)      AD blocks, raw bytes, unpadded
    n_pt x (lo hi last valid_bytes)      PT blocks, raw bytes, unpadded
    n_pt x (lo hi)                       CT blocks, zero-filled past the end
    tag_lo tag_hi
"""
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "model"))
from ascon_model import encrypt  # noqa: E402

OUT = "tb/directed/long_vectors.hex"
SEED = 20260927
MAX_BLOCKS = 32  # must match tb_long.v


def le64(b):
    return int.from_bytes(b.ljust(8, b"\0"), "little")


def blocks(data, present):
    if not present:
        return []
    n = (len(data) + 1 + 15) // 16
    out = []
    for i in range(n):
        chunk = data[16 * i:16 * i + 16]
        last = i == n - 1
        out.append((le64(chunk[0:8]), le64(chunk[8:16]), int(last),
                    len(chunk) if last else 16))
    return out


def main():
    rng = random.Random(SEED)
    # edge lengths first (0, around block boundaries, long multiples of 16),
    # then random ones
    lengths = [(0, 0), (0, 255), (255, 0), (16, 16), (48, 64), (64, 48),
               (15, 17), (17, 15), (31, 33), (160, 240), (240, 160), (255, 255)]
    while len(lengths) < 60:
        lengths.append((rng.randint(0, 255), rng.randint(0, 255)))

    words = [len(lengths)]
    for ad_len, pt_len in lengths:
        key = bytes(rng.randrange(256) for _ in range(16))
        nonce = bytes(rng.randrange(256) for _ in range(16))
        ad = bytes(rng.randrange(256) for _ in range(ad_len))
        pt = bytes(rng.randrange(256) for _ in range(pt_len))
        ct, tag = encrypt(key, nonce, ad, pt)

        ad_b = blocks(ad, ad_len > 0)
        pt_b = blocks(pt, True)
        assert len(ad_b) <= MAX_BLOCKS and len(pt_b) <= MAX_BLOCKS
        words += [le64(key[:8]), le64(key[8:]), le64(nonce[:8]), le64(nonce[8:]),
                  len(ad_b), len(pt_b)]
        for b in ad_b:
            words += list(b)
        for b in pt_b:
            words += list(b)
        for i in range(len(pt_b)):
            c = ct[16 * i:16 * i + 16]
            words += [le64(c[0:8]), le64(c[8:16])]
        words += [le64(tag[:8]), le64(tag[8:])]

    with open(OUT, "w") as f:
        f.write("\n".join("%016x" % w for w in words) + "\n")
    print("wrote %s (%d vectors, %d words)" % (OUT, len(lengths), len(words)))


if __name__ == "__main__":
    main()
