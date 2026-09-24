#!/usr/bin/env python3
"""Find the ZN504XG-D stock `reservearea` partition inside a whole-flash backup.

The stock kernel lays out its raw NAND partitions at run time and skips bad
blocks while doing so, so a whole-chip dump does not tell you where
`reservearea` (MAC, PON serial, optical calibration; 0x240000 bytes) starts.
This tool finds it by content instead of by offset:

  * identity anchor  - the model string (`ZN504XG-D`) at partition offset
                       0x141010 and the base MAC as 12 hex ASCII chars at
                       0x141024 (what preinit/90_airoha_ubi_mac reads);
                       both sit in partition eraseblock 10
  * calibration      - the SFF-8472 A0/A2 pages at 0x1c0400 (what
                       pbs05/ponwrt reads as pon_calibration), eraseblock 14;
                       an A0 page is recognised by its CC_BASE checksum
                       and a printable vendor name

A hit only counts when it lands on the right offset inside a 128 KiB
eraseblock (partitions are eraseblock-aligned). If the calibration block
sits further than 4 blocks after the identity block, the extra blocks in
between are taken as skipped bad blocks. Blocks before eraseblock 10 have no
anchor: a bad block there cannot be seen from the data, so pass it with
--skip (U-Boot `mtd bad`, or "Bad eraseblock" lines in the stock dmesg).

With -o it writes exactly 0x240000 bytes (the size of the `factory` volume,
web-uboot/boards/an7581_znxt_zn504xg-d), ready for the web U-Boot
"按卷写入" page, volume `factory`.

    scripts/find-reservearea.py backup.bin
    scripts/find-reservearea.py backup.bin -o reservearea.bin
    scripts/find-reservearea.py backup.bin --skip 0xfd40000 -o reservearea.bin
    scripts/find-reservearea.py backup.bin --start 0xfc80000 -o reservearea.bin

The input must be a data-only dump (web U-Boot 备份下载, dd of /dev/mtdX, or
`mtd read`), without OOB. Python 3 standard library only.
"""
import argparse
import mmap
import os
import re
import struct
import sys

BLOCK = 0x20000                 # SPI NAND eraseblock
PAGE, OOB = 2048, 128
PART_SIZE = 0x240000            # factory_vols=factory:0x240000
PART_BLOCKS = PART_SIZE // BLOCK
MODEL_OFF = 0x141010
MAC_OFF = 0x141024
CAL_OFF = 0x1c0400              # A0 page; A2 follows at +0x100
ID_LBLK = MODEL_OFF // BLOCK    # 10
CAL_LBLK = CAL_OFF // BLOCK     # 14
MAX_SHIFT = 4                   # at most this many bad blocks between them
MODEL_RE = re.compile(rb'ZN5[0-9]{2}XG-D')
EXPECT_MODEL = b'ZN504XG-D'
HEX12 = re.compile(rb'[0-9A-Fa-f]{12}\Z')

SHOW_MAC = False


def die(msg):
    print('错误: %s' % msg, file=sys.stderr)
    sys.exit(1)


def num(s):
    try:
        return int(s, 0)
    except ValueError:
        raise argparse.ArgumentTypeError('不是数字: %s' % s)


def fmt_mac(h):
    h = h.upper()
    parts = [h[i:i + 2] for i in range(0, 12, 2)]
    if not SHOW_MAC:
        parts[3] = parts[4] = '**'
    return ':'.join(parts)


def read_mac(f, off):
    """12 hex ASCII chars at off -> 'aabbccddeeff' if a usable unicast MAC."""
    raw = bytes(f[off:off + 12])
    if not HEX12.match(raw):
        return None
    v = int(raw, 16)
    if v == 0 or (v >> 40) & 1:
        return None
    return raw.decode()


def uniform(b):
    return b.count(b[:1]) == len(b)


def a0_page(f, off):
    """SFF-8472 A0 page at off: (ok, vendor name)."""
    a0 = bytes(f[off:off + 256])
    a2 = bytes(f[off + 256:off + 512])
    if len(a0) < 256 or uniform(a0):
        return False, None
    vendor = a0[20:36]
    printable = vendor.strip(b' \0') != b'' and all(
        32 <= c < 127 for c in vendor.rstrip(b'\0'))
    if not printable:
        return False, None
    cc_base = sum(a0[:63]) & 0xff == a0[63]
    cc_dmi = len(a2) == 256 and not uniform(a2) and \
        sum(a2[:95]) & 0xff == a2[95]
    ok = cc_base or (a0[0] == 0x03 and cc_dmi)
    return ok, vendor.rstrip(b' \0').decode('ascii')


def classify(f, off):
    if off < 0 or off + BLOCK > len(f):
        return '越界'
    b = f[off:off + BLOCK]
    if b.count(b'\xff') == BLOCK:
        return '全 FF'
    if b.count(b'\0') == BLOCK:
        return '全 00'
    if off >= BLOCK and f[off - BLOCK:off] == b:
        return '与上一块相同'
    if off + 2 * BLOCK <= len(f) and f[off + BLOCK:off + 2 * BLOCK] == b:
        return '与下一块相同'
    return '数据'


def suspicious(cls):
    return cls != '数据'


# ---------------------------------------------------------------- UBI hints

def ubi_info(f):
    """(number of blocks with a UBI EC header, volume names, peb->vid)."""
    n = 0
    names = []
    vids = {}
    for off in range(0, len(f) - BLOCK + 1, BLOCK):
        if f[off:off + 4] != b'UBI#':
            continue
        n += 1
        vid_off, data_off = struct.unpack('>II', f[off + 16:off + 24])
        if vid_off >= BLOCK or data_off >= BLOCK:
            continue
        vid = f[off + vid_off:off + vid_off + 64]
        if vid[:4] != b'UBI!':
            continue
        vol_id, lnum = struct.unpack('>II', vid[8:16])
        vids[off] = (vol_id, lnum, data_off)
        if vol_id == 0x7fffefff and not names:
            tbl = off + data_off
            for r in range(128):
                rec = f[tbl + r * 172:tbl + (r + 1) * 172]
                if len(rec) < 172 or not struct.unpack('>I', rec[:4])[0]:
                    continue
                nl = struct.unpack('>H', rec[14:16])[0]
                names.append((r, rec[16:16 + min(nl, 127)].decode(
                    'utf-8', 'replace')))
    return n, names, vids


# --------------------------------------------------------------- the search

class Cand(object):
    def __init__(self):
        self.ident = None     # physical offset of partition block 10
        self.cal = None       # physical offset of partition block 14
        self.model = None
        self.mac = None
        self.vendor = None
        self.blocks = []      # 18 physical offsets, logical order
        self.notes = []
        self.guess = False    # dropped blocks without being sure which

    @property
    def start(self):
        return self.blocks[0]

    def score(self):
        s = 0
        if self.model:
            s += 3
        if self.mac:
            s += 2
        if self.cal is not None:
            s += 2
        return s

    def confidence(self):
        if self.model and self.mac and self.cal is not None and not self.guess:
            return '高'
        if self.model and self.mac:
            return '中'
        return '低'


def walk(start, step, count, skip, f):
    """count block offsets from start in direction step, jumping --skip."""
    out = []
    off = start
    while len(out) < count:
        if off < 0 or off + BLOCK > len(f):
            return None
        if off not in skip:
            out.append(off)
        off += step
    return out


def build(c, f, skip):
    anchor = c.ident if c.ident is not None else c.cal - (CAL_LBLK - ID_LBLK) * BLOCK
    head = walk(anchor - BLOCK, -BLOCK, ID_LBLK, skip, f)
    if head is None:
        c.notes.append('分区开头会落在文件之外')
        return False
    head.reverse()
    need = CAL_LBLK - ID_LBLK - 1                       # blocks 11..13
    if c.ident is not None and c.cal is not None:
        between = [o for o in range(c.ident + BLOCK, c.cal, BLOCK)
                   if o not in skip]
        extra = len(between) - need
        if extra < 0:
            c.notes.append('校准页比预期更靠前，忽略这个锚点（-s 已排除太多块？）')
            c.cal = None
        elif extra:
            cls = dict((o, classify(f, o)) for o in between)
            bad = [o for o in between if suspicious(cls[o])]
            if len(bad) == extra:
                drop = bad
            else:
                c.guess = True
                rank = {'与上一块相同': 0, '与下一块相同': 0, '全 00': 1, '全 FF': 2}
                drop = sorted(bad, key=lambda o: (rank.get(cls[o], 3), o))[:extra]
                if len(drop) < extra:           # nothing looks bad: take the last ones
                    rest = [o for o in between if o not in drop]
                    drop += rest[len(rest) - (extra - len(drop)):]
                c.notes.append(
                    '块 10 与块 14 之间多出 %d 块，但看不出是哪%s块坏了，'
                    '按「重复 > 全 00 > 全 FF」猜的；确定坏块后用 --skip 指定'
                    % (extra, '一' if extra == 1 else '几'))
            for o in drop:
                c.notes.append('0x%08x 视为坏块跳过（%s）' % (o, classify(f, o)))
            mid = [o for o in between if o not in drop]
        else:
            mid = between
        if c.cal is not None:
            tail = walk(c.cal + BLOCK, BLOCK, PART_BLOCKS - CAL_LBLK - 1, skip, f)
            if tail is None:
                c.notes.append('分区结尾会落在文件之外')
                return False
            c.blocks = head + [c.ident] + mid + [c.cal] + tail
            return True
    if c.ident is not None:
        tail = walk(c.ident + BLOCK, BLOCK, PART_BLOCKS - ID_LBLK - 1, skip, f)
        mid = [c.ident]
    else:
        # calibration only: block 10 has no identity, keep the 4-block spacing
        head = walk(c.cal - BLOCK, -BLOCK, CAL_LBLK, skip, f)
        if head is None:
            c.notes.append('分区开头会落在文件之外')
            return False
        head.reverse()
        mid = [c.cal]
        tail = walk(c.cal + BLOCK, BLOCK, PART_BLOCKS - CAL_LBLK - 1, skip, f)
    if tail is None:
        c.notes.append('分区结尾会落在文件之外')
        return False
    c.blocks = head + mid + tail
    return True


def search(f, skip):
    cands = []
    stray = []
    for m in MODEL_RE.finditer(f):
        p = m.start()
        if p % BLOCK != MODEL_OFF % BLOCK:
            stray.append((p, m.group()))
            continue
        c = Cand()
        c.ident = p - (MODEL_OFF % BLOCK)
        c.model = m.group().decode()
        c.mac = read_mac(f, c.ident + MAC_OFF % BLOCK)
        cands.append(c)

    cal_hits = {}
    for off in range(0, len(f) - BLOCK + 1, BLOCK):
        ok, vendor = a0_page(f, off + CAL_OFF % BLOCK)
        if ok:
            cal_hits[off] = vendor

    used = set()
    for c in cands:
        for k in range(MAX_SHIFT + 1):
            o = c.ident + (CAL_LBLK - ID_LBLK + k) * BLOCK
            if o in cal_hits and o not in used:
                c.cal, c.vendor = o, cal_hits[o]
                used.add(o)
                if k:
                    c.notes.append('校准页比预期靠后 %d 块' % k)
                break
        else:
            c.notes.append('块 14 处没认出校准页（A0/A2），坏块只能靠 --skip 指定')
    for o, vendor in sorted(cal_hits.items()):
        if o in used:
            continue
        c = Cand()
        c.cal, c.vendor = o, vendor
        c.notes.append('只找到校准页，没有型号与 MAC：块 10 可能坏了或被擦过')
        cands.append(c)

    good = [c for c in cands if build(c, f, skip)]
    good.sort(key=lambda c: (-c.score(), c.start))
    return good, stray, cal_hits


def forced(f, start, skip):
    c = Cand()
    c.blocks = walk(start, BLOCK, PART_BLOCKS, skip, f)
    if c.blocks is None:
        die('--start 0x%x 往后不够 0x%x 字节' % (start, PART_SIZE))
    c.ident, c.cal = c.blocks[ID_LBLK], c.blocks[CAL_LBLK]
    m = MODEL_RE.match(bytes(f[c.ident + MODEL_OFF % BLOCK:
                               c.ident + MODEL_OFF % BLOCK + 9]))
    c.model = m.group().decode() if m else None
    c.mac = read_mac(f, c.ident + MAC_OFF % BLOCK)
    ok, c.vendor = a0_page(f, c.cal + CAL_OFF % BLOCK)
    if not ok:
        c.cal = None
    c.notes.append('起点由 --start 指定')
    return c


# ------------------------------------------------------------------- output

def describe(c, f, idx=None):
    tag = '' if idx is None else '候选 %d：' % idx
    print('%s起点 0x%08x，置信度 %s' % (tag, c.start, c.confidence()))
    if c.model:
        extra = '' if c.model == EXPECT_MODEL.decode() else \
            '（不是 %s，确认机型）' % EXPECT_MODEL.decode()
        print('  型号     %-12s @ 0x%08x%s' % (
            c.model, c.ident + MODEL_OFF % BLOCK, extra))
    else:
        print('  型号     未找到')
    if c.mac:
        print('  基础 MAC %-17s @ 0x%08x' % (fmt_mac(c.mac),
                                            c.ident + MAC_OFF % BLOCK))
    elif c.ident is not None:
        print('  基础 MAC 0x141024 处不是有效的 12 位十六进制 MAC')
    if c.cal is not None:
        print('  校准页   厂商 %-12s @ 0x%08x' % (c.vendor,
                                               c.cal + CAL_OFF % BLOCK))
    for n in c.notes:
        print('  ! %s' % n)


def block_map(c, f):
    lo, hi = c.blocks[0] - BLOCK, c.blocks[-1] + BLOCK
    logical = dict((o, i) for i, o in enumerate(c.blocks))
    print('  物理偏移     分区块  内容')
    for o in range(max(lo, 0), min(hi, len(f) - BLOCK) + 1, BLOCK):
        if o in logical:
            i = logical[o]
            mark = {ID_LBLK: ' ← 型号/MAC', CAL_LBLK: ' ← 校准页'}.get(i, '')
            print('  0x%08x   %2d      %s%s' % (o, i, classify(f, o), mark))
        elif c.blocks[0] < o < c.blocks[-1]:
            print('  0x%08x   跳过    %s' % (o, classify(f, o)))
        else:
            print('  0x%08x   分区外  %s' % (o, classify(f, o)))
    n_ff = sum(1 for o in c.blocks if classify(f, o) == '全 FF')
    if n_ff:
        print('  （分区内 %d 块全 FF：reservearea 本来就有空块，全 FF 不等于坏块）'
              % n_ff)
    if classify(f, c.blocks[0] - BLOCK) == '数据':
        print('  （起点前一块也有数据。块 0~9 没有锚点，那里若有坏块，真正的起点还要往前挪，')
        print('   请用 --skip 标出坏块。固件只读块 10 的 MAC 与块 14 的校准页，这两块不受影响）')


def not_found(f, stray):
    print('没有找到 reservearea：没有任何擦除块在 0x%x 处有 ZN5xxXG-D，'
          '也没有块在 0x%x 处有校准页。' % (MODEL_OFF % BLOCK, CAL_OFF % BLOCK))
    n, names, vids = ubi_info(f)
    total = len(f) // BLOCK
    ubi_copy = False
    for p, s in stray[:8]:
        peb = p - p % BLOCK
        where = '，不是裸分区里该在的位置'
        if peb in vids:
            vol_id, lnum, data_off = vids[peb]
            vname = dict(names).get(vol_id, 'id %d' % vol_id)
            if lnum * (BLOCK - data_off) + (p - peb - data_off) == MODEL_OFF:
                ubi_copy = True
                where = '。它在 UBI 卷「%s」的 0x%x 处，这个卷就是 reservearea ' \
                        '的拷贝：用网页 U-Boot「备份下载」直接导出该卷即可' % (vname, MODEL_OFF)
            else:
                where = '，在 UBI 卷「%s」里' % vname
        print('  0x%08x 有 %s，但不在擦除块内 0x%x 处%s' % (
            p, s.decode(), MODEL_OFF % BLOCK, where))
    if len(stray) > 8:
        print('  ……另有 %d 处同类字符串' % (len(stray) - 8))
    if total and n * 10 >= total * 9 and not ubi_copy:
        vols = '、'.join(nm for _, nm in names) or '（读不到卷表）'
        print('\n这份备份 %d/%d 块都带 UBI 头，卷有：%s。' % (n, total, vols))
        if any(nm == 'factory' for _, nm in names):
            print('卷表里有 factory 卷，那就是 reservearea 的拷贝：用网页 U-Boot「备份下载」导出它。')
        else:
            print('原厂系统里 reservearea 是 UBI 之外的裸分区。整片几乎都是 UBI，说明 UBI 之外的')
            print('原厂分区已经被擦掉了：U-Boot 或内核挂载覆盖整片的 ubi 分区时，会把不认识的')
            print('块全部擦除并写上 UBI 头。这份备份里已经没有 reservearea，要找挂载之前做的备份。')
    sys.exit(2)


def main():
    global SHOW_MAC
    ap = argparse.ArgumentParser(
        description='在 ZN504XG-D 的整片备份里按内容找出原厂 reservearea，'
                    '可选导出为 factory 卷镜像（0x240000 字节）。')
    ap.add_argument('backup', help='整片备份（不含 OOB）')
    ap.add_argument('-o', '--output', help='导出 reservearea 到这个文件')
    ap.add_argument('-f', '--force', action='store_true',
                    help='输出文件已存在时覆盖；置信度低或有多个候选时仍导出')
    ap.add_argument('--start', type=num,
                    help='不搜索，直接用这个物理偏移当分区开头')
    ap.add_argument('--skip', type=num, action='append', default=[],
                    metavar='OFFSET', help='这个物理偏移处的擦除块是坏块（可重复）')
    ap.add_argument('--show-mac', action='store_true',
                    help='完整显示 MAC（默认打码中间两字节，方便贴日志）')
    a = ap.parse_args()
    SHOW_MAC = a.show_mac

    for s in a.skip + ([a.start] if a.start is not None else []):
        if s % BLOCK:
            die('0x%x 不在 128 KiB 擦除块边界上' % s)
    skip = set(a.skip)

    size = os.path.getsize(a.backup)
    if size < PART_SIZE:
        die('%s 只有 %d 字节，比 reservearea（0x%x）还小' % (a.backup, size, PART_SIZE))
    per_blk_oob = BLOCK // PAGE * (PAGE + OOB)

    def pow2(n):
        return n and not n & (n - 1)
    if size % per_blk_oob == 0 and pow2(size // per_blk_oob) and \
            not (size % BLOCK == 0 and pow2(size // BLOCK)):
        die('文件大小 0x%x 正好是 %d 个「2048+128 字节页」的擦除块，像是带 OOB 的'
            '原始转储。本工具只认纯数据区的备份（网页 U-Boot 的整片备份、dd /dev/mtdX）'
            % (size, size // per_blk_oob))
    if size % BLOCK:
        print('注意: 文件大小 0x%x 不是 128 KiB 的整数倍，末尾不完整的块不参与搜索' % size)
    elif size != 0x10000000 and size != PART_SIZE:
        print('注意: 文件 %d MiB，不是 256 MiB 的整片备份；照样搜，偏移按文件开头算'
              % (size >> 20))

    with open(a.backup, 'rb') as fp:
        f = mmap.mmap(fp.fileno(), 0, access=mmap.ACCESS_READ)
        if a.start is not None:
            best, others = forced(f, a.start, skip), []
        else:
            cands, stray, _ = search(f, skip)
            if not cands:
                not_found(f, stray)
            best, others = cands[0], cands[1:]
            top = [c for c in cands if c.score() == best.score()]
            if len(top) > 1:
                same = all(all(f[o:o + BLOCK] == f[b:b + BLOCK]
                               for o, b in zip(c.blocks, best.blocks))
                           for c in top[1:])
                print('找到 %d 处同样可信的 reservearea：' % len(top))
                for i, c in enumerate(top, 1):
                    describe(c, f, i)
                if same:
                    print('\n这 %d 处内容逐字节相同（整片备份里有重复拷贝），用第一处。'
                          % len(top))
                else:
                    print('\n内容不一样，没法自动判断用哪一处。用 --start 指定起点后再导出。')
                    if a.output and not a.force:
                        sys.exit(3)
                print()
            elif stray:
                print('（另有 %d 处 ZN5xxXG-D 不在擦除块内 0x%x 处，是固件里的字符串'
                      '或 UBI 卷里的副本，已忽略）' % (len(stray), MODEL_OFF % BLOCK))

        describe(best, f)
        block_map(best, f)
        for c in others:
            if c.score() < best.score():
                print('另有较弱的候选：起点 0x%08x，置信度 %s' % (c.start, c.confidence()))

        if not a.output:
            return
        if best.confidence() == '低' and not a.force:
            die('置信度低，不导出。确认无误后加 --force，或用 --start 指定起点')
        if os.path.exists(a.output):
            if os.path.samefile(a.output, a.backup):
                die('输出文件就是输入的备份')
            if not a.force:
                die('%s 已存在，加 --force 覆盖' % a.output)
        data = b''.join(f[o:o + BLOCK] for o in best.blocks)
        f.close()

    assert len(data) == PART_SIZE
    with open(a.output, 'wb') as out:
        out.write(data)
    chk = []
    chk.append('型号 %s' % ('✔' if MODEL_RE.match(data[MODEL_OFF:MODEL_OFF + 9]) else '✘'))
    chk.append('MAC %s' % ('✔' if read_mac(data, MAC_OFF) else '✘'))
    chk.append('校准页 %s' % ('✔' if a0_page(data, CAL_OFF)[0] else '✘'))
    print('\n已写出 %s（0x%x 字节）：%s' % (a.output, len(data), '，'.join(chk)))
    print('在网页 U-Boot「按卷写入」里选卷 factory，上传这个文件；重启后串口应有 '
          '"MAC … from factory volume"。')


if __name__ == '__main__':
    main()
