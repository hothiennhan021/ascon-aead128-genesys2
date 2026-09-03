#!/usr/bin/env python3
"""Drive the Genesys 2 UART demo (rtl/demo/top_board.v) through the
full NIST KAT vector set over a real serial port, using pyserial.

Protocol (rtl/demo/cmd_fsm.v, docs/spec.md section 7 register map),
little-endian / LSB-byte-first -- same padding rules as
model/ascon_model.py (the golden reference) and every RTL testbench
in this project:
    0x01 addr d0 d1 d2 d3   WRITE        (no reply)
    0x02 addr               READ         (replies with 4 bytes)
    0x03                    READ_STATUS  (replies with 4 bytes)

This script only exercises ENCRYPT (mirrors model.run_kat's own
encrypt-and-compare-against-CT check); it does not drive TAGIN/decrypt.

Usage:
    python scripts/uart_kat.py --port COM5
    python scripts/uart_kat.py --port /dev/ttyUSB1 --limit 20
"""
import argparse
import sys
import time

OP_WRITE       = 0x01  # UART framing opcode
OP_READ        = 0x02
OP_READ_STATUS = 0x03

CMD_INIT      = 1  # ascon_apb CMD register opcode field (docs/spec.md 7.1)
CMD_PROC_AD   = 2
CMD_PROC_TEXT = 3
CMD_FINAL     = 4

ADDR_CMD    = 0x00
ADDR_STATUS = 0x04
ADDR_KEY0   = 0x10
ADDR_NONCE0 = 0x20
ADDR_DIN0   = 0x30
ADDR_DOUT0  = 0x40
ADDR_TAG0   = 0x50

STATUS_BUSY_BIT       = 0
STATUS_DONE_BIT       = 1
STATUS_DOUT_VALID_BIT = 2
STATUS_TAG_VALID_BIT  = 3
STATUS_TAG_FAIL_BIT   = 4


def build_cmd(op, last, mode, valid_bytes):
    w = op & 0x7
    if last:
        w |= 1 << 3
    if mode:
        w |= 1 << 4
    w |= (valid_bytes & 0x1F) << 8
    return w


def split_blocks(data):
    """16-byte block split matching docs/spec.md 8.3/9.4: a length
    that is an exact nonzero multiple of 16 still gets one extra empty
    padding block; empty input gets exactly one empty block. Returns
    a list of (chunk_bytes, valid_bytes, is_last)."""
    n = len(data)
    full_blocks = n // 16
    remainder = n % 16
    blocks = [(data[i*16:(i+1)*16], 16, False) for i in range(full_blocks)]
    if remainder == 0:
        blocks.append((b'', 0, True))
    else:
        blocks.append((data[full_blocks*16:], remainder, True))
    return blocks


class UartAscon:
    def __init__(self, port, baud=115200, timeout=2.0):
        import serial  # lazy import: keeps build_cmd/split_blocks/parse_kat
                        # importable and unit-testable without pyserial installed
        self.ser = serial.Serial(port, baud, timeout=timeout)

    def close(self):
        self.ser.close()

    def write_reg(self, addr, data32):
        pkt = bytes([OP_WRITE, addr]) + data32.to_bytes(4, 'little')
        self.ser.write(pkt)

    def read_reg(self, addr):
        self.ser.write(bytes([OP_READ, addr]))
        return int.from_bytes(self._read_exact(4), 'little')

    def read_status(self):
        self.ser.write(bytes([OP_READ_STATUS]))
        return int.from_bytes(self._read_exact(4), 'little')

    def _read_exact(self, n):
        data = self.ser.read(n)
        if len(data) != n:
            raise TimeoutError(
                'expected %d bytes from board, got %d -- check port/baud/wiring'
                % (n, len(data)))
        return data

    def wait_done(self, timeout_s=2.0):
        deadline = time.time() + timeout_s
        while True:
            status = self.read_status()
            if status & (1 << STATUS_DONE_BIT):
                return status
            if time.time() > deadline:
                raise TimeoutError('STATUS.done never set -- board hung or not responding')

    def write_block16(self, base_addr, data16):
        padded = data16 + b'\x00' * (16 - len(data16))
        for i in range(4):
            word = int.from_bytes(padded[4*i:4*i+4], 'little')
            self.write_reg(base_addr + 4*i, word)

    def read_block16(self, base_addr):
        out = b''
        for i in range(4):
            out += self.read_reg(base_addr + 4*i).to_bytes(4, 'little')
        return out

    def encrypt(self, key, nonce, ad, pt):
        self.write_block16(ADDR_KEY0, key)
        self.write_block16(ADDR_NONCE0, nonce)
        self.write_reg(ADDR_CMD, build_cmd(CMD_INIT, 0, 0, 0))
        self.wait_done()

        if ad:  # docs/spec.md 8.3: AD rong -> khong gui PROC_AD lan nao
            for chunk, vb, last in split_blocks(ad):
                self.write_block16(ADDR_DIN0, chunk)
                self.write_reg(ADDR_CMD, build_cmd(CMD_PROC_AD, last, 0, vb))
                self.wait_done()

        ct = b''
        for chunk, vb, last in split_blocks(pt):  # always >=1 block, even if pt is empty
            self.write_block16(ADDR_DIN0, chunk)
            self.write_reg(ADDR_CMD, build_cmd(CMD_PROC_TEXT, last, 0, vb))
            status = self.wait_done()
            if status & (1 << STATUS_DOUT_VALID_BIT):
                dout = self.read_block16(ADDR_DOUT0)
                ct += dout[:vb] if last else dout
            else:
                raise RuntimeError('expected dout_valid for a PT block, got STATUS=%#x' % status)

        self.write_reg(ADDR_CMD, build_cmd(CMD_FINAL, 0, 0, 0))
        status = self.wait_done()
        if not (status & (1 << STATUS_TAG_VALID_BIT)):
            raise RuntimeError('STATUS.tag_valid not set after FINAL (STATUS=%#x)' % status)
        tag = self.read_block16(ADDR_TAG0)
        return ct, tag


def parse_kat(path):
    with open(path) as f:
        text = f.read()
    vectors = []
    for block in text.strip().split('\n\n'):
        if not block.strip():
            continue
        fields = {}
        for line in block.strip().splitlines():
            k, _, v = line.partition('=')
            fields[k.strip()] = v.strip()
        vectors.append({
            'count': int(fields['Count']),
            'key': bytes.fromhex(fields['Key']),
            'nonce': bytes.fromhex(fields['Nonce']),
            'pt': bytes.fromhex(fields['PT']),
            'ad': bytes.fromhex(fields['AD']),
            'ct_expected': bytes.fromhex(fields['CT']),
        })
    return vectors


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', required=True, help='serial port, e.g. COM5 or /dev/ttyUSB1')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--kat', default='vectors/LWC_AEAD_KAT_128_128.txt')
    ap.add_argument('--limit', type=int, default=None, help='only run the first N vectors')
    ap.add_argument('--timeout', type=float, default=2.0,
                     help='per read_status/wait_done timeout in seconds')
    args = ap.parse_args()

    vectors = parse_kat(args.kat)
    if args.limit is not None:
        vectors = vectors[:args.limit]
    total = len(vectors)

    board = UartAscon(args.port, args.baud, timeout=args.timeout)
    passed = 0
    first_fail = None
    try:
        for v in vectors:
            try:
                ct, tag = board.encrypt(v['key'], v['nonce'], v['ad'], v['pt'])
            except (TimeoutError, RuntimeError) as exc:
                print('FAIL Count=%d: %s' % (v['count'], exc))
                if first_fail is None:
                    first_fail = (v['count'], len(v['ad']), len(v['pt']))
                continue
            if ct + tag == v['ct_expected']:
                passed += 1
            else:
                if first_fail is None:
                    first_fail = (v['count'], len(v['ad']), len(v['pt']))
                print('FAIL Count=%d AD_len=%d PT_len=%d' % (v['count'], len(v['ad']), len(v['pt'])))
    finally:
        board.close()

    if first_fail is not None:
        print('First fail: Count=%d AD_len=%d PT_len=%d' % first_fail)
    print('PASSED %d/%d' % (passed, total))
    sys.exit(0 if passed == total else 1)


if __name__ == '__main__':
    main()
