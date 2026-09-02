import sys

MASK = (1 << 64) - 1
RC = [0x3c, 0x2d, 0x1e, 0x0f, 0xf0, 0xe1, 0xd2, 0xc3,
      0xb4, 0xa5, 0x96, 0x87, 0x78, 0x69, 0x5a, 0x4b]
IV = 0x00001000808c0001


def rotr(x, n):
    return ((x >> n) | (x << (64 - n))) & MASK


def b2w(b):
    return int.from_bytes(b, 'little')


def w2b(w):
    return (w & MASK).to_bytes(8, 'little')


def round_fn(S, idx):
    x0, x1, x2, x3, x4 = S
    x2 ^= RC[idx]
    x0 ^= x4
    x4 ^= x3
    x2 ^= x1
    t0 = (~x0 & MASK) & x1
    t1 = (~x1 & MASK) & x2
    t2 = (~x2 & MASK) & x3
    t3 = (~x3 & MASK) & x4
    t4 = (~x4 & MASK) & x0
    x0 ^= t1
    x1 ^= t2
    x2 ^= t3
    x3 ^= t4
    x4 ^= t0
    x1 ^= x0
    x0 ^= x4
    x3 ^= x2
    x2 ^= MASK
    x0 ^= rotr(x0, 19) ^ rotr(x0, 28)
    x1 ^= rotr(x1, 61) ^ rotr(x1, 39)
    x2 ^= rotr(x2, 1) ^ rotr(x2, 6)
    x3 ^= rotr(x3, 10) ^ rotr(x3, 17)
    x4 ^= rotr(x4, 7) ^ rotr(x4, 41)
    return [x0, x1, x2, x3, x4]


def perm(S, rounds):
    for i in range(rounds):
        S = round_fn(S, 16 - rounds + i)
    return S


def pad16(data):
    return data + b'\x01' + b'\x00' * ((-(len(data) + 1)) % 16)


def init(key, nonce):
    k0, k1 = b2w(key[0:8]), b2w(key[8:16])
    S = [IV, k0, k1, b2w(nonce[0:8]), b2w(nonce[8:16])]
    S = perm(S, 12)
    S[3] ^= k0
    S[4] ^= k1
    return S


def absorb_ad(S, ad):
    if len(ad) > 0:
        a = pad16(ad)
        for i in range(0, len(a), 16):
            S[0] ^= b2w(a[i:i + 8])
            S[1] ^= b2w(a[i + 8:i + 16])
            S = perm(S, 8)
    S[4] ^= 0x8000000000000000
    return S


def finalize(S, key):
    k0, k1 = b2w(key[0:8]), b2w(key[8:16])
    S[2] ^= k0
    S[3] ^= k1
    S = perm(S, 12)
    return w2b(S[3] ^ k0) + w2b(S[4] ^ k1)


def encrypt(key, nonce, ad, pt):
    S = absorb_ad(init(key, nonce), ad)
    p = pad16(pt)
    n = len(p) // 16
    ct = b''
    for i in range(n):
        blk = p[16 * i:16 * i + 16]
        S[0] ^= b2w(blk[0:8])
        S[1] ^= b2w(blk[8:16])
        ct += w2b(S[0]) + w2b(S[1])
        if i < n - 1:
            S = perm(S, 8)
    return ct[:len(pt)], finalize(S, key)


def decrypt(key, nonce, ad, ct, tag):
    S = absorb_ad(init(key, nonce), ad)
    m = len(ct)
    nblk = (m + 16) // 16
    pt = b''
    for i in range(nblk - 1):
        blk = ct[16 * i:16 * i + 16]
        pt += w2b(S[0] ^ b2w(blk[0:8])) + w2b(S[1] ^ b2w(blk[8:16]))
        S[0] = b2w(blk[0:8])
        S[1] = b2w(blk[8:16])
        S = perm(S, 8)
    last = ct[16 * (nblk - 1):]
    l = len(last)
    rate = w2b(S[0]) + w2b(S[1])
    p_last = bytes(a ^ b for a, b in zip(rate[:l], last))
    pt += p_last
    padded = pad16(p_last)[:16]
    S[0] ^= b2w(padded[0:8])
    S[1] ^= b2w(padded[8:16])
    if finalize(S, key) != tag:
        return None
    return pt


def run_kat(path):
    with open(path) as f:
        text = f.read()
    blocks = [b for b in text.strip().split('\n\n') if b.strip()]
    total = len(blocks)
    passed = 0
    first_fail = None
    for block in blocks:
        fields = {}
        for line in block.strip().splitlines():
            k, _, v = line.partition('=')
            fields[k.strip()] = v.strip()
        count = int(fields['Count'])
        key = bytes.fromhex(fields['Key'])
        nonce = bytes.fromhex(fields['Nonce'])
        pt = bytes.fromhex(fields['PT'])
        ad = bytes.fromhex(fields['AD'])
        ct_expected = bytes.fromhex(fields['CT'])
        ct, tag = encrypt(key, nonce, ad, pt)
        if ct + tag == ct_expected:
            passed += 1
        elif first_fail is None:
            first_fail = (count, len(ad), len(pt))
    if first_fail is not None:
        print('First fail: Count=%d AD_len=%d PT_len=%d' % first_fail)
    print('PASSED %d/%d' % (passed, total))
    return passed == total


if __name__ == '__main__':
    if '--run-kat' in sys.argv:
        kat_path = sys.argv[sys.argv.index('--run-kat') + 1]
        ok = run_kat(kat_path)
        sys.exit(0 if ok else 1)
