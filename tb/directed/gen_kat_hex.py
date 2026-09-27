#!/usr/bin/env python3
"""Regenerate tb/directed/kat_128_128.hex from the NIST KAT file.

Input : vectors/LWC_AEAD_KAT_128_128.txt (official NIST file)
Output: tb/directed/kat_128_128.hex ($readmemh, 64-bit words, 8 per line)

Per vector, 41 words (the layout read by tb_aead.v / tb_apb.v /
tb_apb_session.v / gen_gatesim_kat.py):

  [0]      Count
  [1..2]   Key   (lo, hi)      little-endian 64-bit words
  [3..4]   Nonce (lo, hi)
  [5]      n_ad  = number of AD blocks (0 if AD is empty, else ceil((len+1)/16))
  [6]      n_pt  = number of PT blocks (always ceil((len+1)/16) >= 1)
  [7]      AD length in bytes
  [8]      PT length in bytes
  [9..20]  3 AD slots x (lo, hi, last, valid_bytes)
  [21..32] 3 PT slots x (lo, hi, last, valid_bytes)
  [33..38] 3 CT slots x (lo, hi)
  [39..40] Tag (lo, hi)

Block data is the raw bytes, zero-filled and NOT padded: the 0x01 pad
byte is inserted by the RTL from valid_bytes/last. Only the NIST file is
read -- model/ascon_model.py is not involved, so the hex is independent
ground truth.

Usage (from the repo root):
    python tb/directed/gen_kat_hex.py            # rewrite the .hex
    python tb/directed/gen_kat_hex.py --check    # exit 1 if it differs
"""
import sys

KAT = "vectors/LWC_AEAD_KAT_128_128.txt"
OUT = "tb/directed/kat_128_128.hex"
SLOTS = 3


def le64(b):
    return int.from_bytes(b.ljust(8, b"\0"), "little")


def blocks(data, present):
    """Split into (lo, hi, last, valid_bytes) tuples, SP 800-232 style."""
    if not present:
        return []
    n = (len(data) + 1 + 15) // 16
    out = []
    for i in range(n):
        chunk = data[16 * i:16 * i + 16]
        last = (i == n - 1)
        out.append((le64(chunk[0:8]), le64(chunk[8:16]), int(last),
                    len(chunk) if last else 16))
    return out


def vector_words(f):
    key = bytes.fromhex(f["Key"])
    nonce = bytes.fromhex(f["Nonce"])
    pt = bytes.fromhex(f["PT"])
    ad = bytes.fromhex(f["AD"])
    ct_full = bytes.fromhex(f["CT"])
    ct, tag = ct_full[:-16], ct_full[-16:]

    ad_b = blocks(ad, len(ad) > 0)
    pt_b = blocks(pt, True)
    w = [int(f["Count"]), le64(key[:8]), le64(key[8:]),
         le64(nonce[:8]), le64(nonce[8:]),
         len(ad_b), len(pt_b), len(ad), len(pt)]
    for s in range(SLOTS):
        w += list(ad_b[s]) if s < len(ad_b) else [0, 0, 0, 0]
    for s in range(SLOTS):
        w += list(pt_b[s]) if s < len(pt_b) else [0, 0, 0, 0]
    for s in range(SLOTS):
        if s < len(pt_b):
            c = ct[16 * s:16 * s + 16]
            w += [le64(c[0:8]), le64(c[8:16])]
        else:
            w += [0, 0]
    w += [le64(tag[:8]), le64(tag[8:])]
    assert len(w) == 41
    return w


def main():
    text = open(KAT).read().strip()
    words = []
    for blk in text.split("\n\n"):
        if not blk.strip():
            continue
        f = {}
        for line in blk.strip().splitlines():
            k, _, v = line.partition("=")
            f[k.strip()] = v.strip()
        words += vector_words(f)

    lines = [" ".join("%016x" % x for x in words[i:i + 8])
             for i in range(0, len(words), 8)]
    out = "\n".join(lines) + "\n"

    if "--check" in sys.argv:
        same = open(OUT).read() == out
        print("kat_128_128.hex matches NIST KAT" if same
              else "kat_128_128.hex DIFFERS from NIST KAT")
        sys.exit(0 if same else 1)
    open(OUT, "w").write(out)
    print("wrote %s (%d vectors)" % (OUT, len(words) // 41))


if __name__ == "__main__":
    main()
