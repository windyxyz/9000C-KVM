#!/usr/bin/env python3
"""
generic-patch-qemu.py —— 通用 QEMU 定制补丁器（版本无关，供官方新版镜像重新定制）

功能：在 stripped 的 aarch64 QEMU 二进制中，定位一处唯一的"启动检查"指令站点
（MOVZ w0,#N + BL exit 的编码模式，N 为特定退出码），反查全二进制唯一跳转源，
将其置为 NOP（单指令修改）。

设计约束（保证无损）：
  - 站点在全二进制中必须唯一；
  - 跳转源必须唯一，且为 TBZ/TBNZ 测试 w0 符号位的形态；
  - 被修改指令之后该返回值不再被消费；
  - 任一唯一性不成立即中止，需人工分析（防止在新版本上误改）。

背景：镜像随官方版本更新时 QEMU 二进制会变化，补丁偏移随之失效；
本脚本通过编码模式而非固定偏移定位，使定制流程可跨版本复用。
用法: generic-patch-qemu.py <原版二进制> <输出补丁二进制> [退出码，默认 222=0xDE]
"""
import struct, sys, hashlib
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

NOP = 0xD503201F

def signext(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v

def main(src, dst, code=0xDE):
    data = bytearray(open(src, 'rb').read())
    n = len(data) // 4

    # ---- 1. 定位检查站点：MOVZ w0,#<code> 且后随 B/BL ----
    movz = struct.pack('<I', 0x52800000 | (code << 5))
    sites = []
    for off in range(0, len(data) - 16, 4):
        if data[off:off + 4] == movz:
            for j in (4, 8, 12):
                w = struct.unpack_from('<I', data, off + j)[0]
                if (w >> 26) in (0b000101, 0b100101):
                    sites.append(off)
                    break
    print(f'检查站点（MOVZ w0,#{code:#x} + B/BL）: {[hex(o) for o in sites]}')
    if len(sites) != 1:
        sys.exit(f'中止: 站点数 {len(sites)} != 1，检查机制可能已变化，需人工分析')
    exit_va = sites[0]

    # ---- 2. 反查跳转源（全量分支形态）----
    srcs = []
    for i in range(n):
        off = i * 4
        w = struct.unpack_from('<I', data, off)[0]
        if (w >> 26) in (0b000101, 0b100101):
            tgt = off + (signext(w & 0x3FFFFFF, 26) << 2)
            kind = 'B' if (w >> 26) == 0b000101 else 'BL'
        elif (w & 0xFF000010) == 0x54000000:
            tgt = off + (signext((w >> 5) & 0x7FFFF, 19) << 2)
            kind = 'B.cond'
        elif (w & 0x7E000000) == 0x34000000:
            tgt = off + (signext((w >> 5) & 0x7FFFF, 19) << 2)
            kind = 'CBZ' if not (w & 0x01000000) else 'CBNZ'
        elif (w & 0x7E000000) == 0x36000000:
            tgt = off + (signext((w >> 5) & 0x3FFF, 14) << 2)
            kind = 'TBZ/TBNZ'
        else:
            continue
        if tgt == exit_va:
            srcs.append((off, kind))
    print(f'跳转源: {[(hex(o), k) for o, k in srcs]}')
    if len(srcs) != 1:
        sys.exit(f'中止: 跳转源数 {len(srcs)} != 1，需人工分析')
    p_off, p_kind = srcs[0]
    if p_kind != 'TBZ/TBNZ':
        sys.exit(f'中止: 跳转源类型 {p_kind} 非 TBZ/TBNZ，需人工确认后调整脚本')

    # ---- 3. 解码断言 + NOP ----
    w = struct.unpack_from('<I', data, p_off)[0]
    fixed, op = (w >> 25) & 0x3F, (w >> 24) & 1
    b40, rt = (w >> 19) & 0x1F, w & 0x1F
    tgt = p_off + (signext((w >> 5) & 0x3FFF, 14) << 2)
    print(f'补丁点 {p_off:#x}: TBNZ w{rt}, #{b40} -> {tgt:#x}')
    assert fixed == 0b011011 and op == 1 and tgt == exit_va, '指令解码不符'
    assert rt == 0 and b40 in (31, 63), '非符号位测试，需人工确认'
    struct.pack_into('<I', data, p_off, NOP)

    open(dst, 'wb').write(data)
    print(f'补丁完成: {dst}')
    print('sha256:', hashlib.sha256(bytes(data)).hexdigest())

if __name__ == '__main__':
    code = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0xDE
    main(sys.argv[1], sys.argv[2], code)
