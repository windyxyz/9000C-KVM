#!/bin/bash
# =============================================================================
# final-verify.sh —— 定制版镜像出厂终检（对照原版镜像）
#
# 用法: ORIGGZ=<原版.gz> PATGZ=<定制版.gz> KIT=<脚本目录> bash final-verify.sh
#
# 层0 原版身份 | 层1 归档 CRC | 层2 GPT | 层3 e2fsck | 层4 与原版逐字节对照
# 层5 服务状态 | 层5.5 隐私加固 | 层6 定制点动态对照（原版 vs 定制版）
#
# 注意: SIZE/MD5/QEMU/ORIG 三个哈希为版本相关记录，官方更新后需更新本文件头部记录。
# =============================================================================
ORIGGZ="${ORIGGZ:?需设置原版镜像路径}"
PATGZ="${PATGZ:?需设置定制版镜像路径}"
KIT="${KIT:-$(dirname "$0")}"
SIZE_EXPECT="${SIZE_EXPECT:?需设置定制版大小}"
MD5_EXPECT="${MD5_EXPECT:?需设置定制版md5}"
QEMU_SHA="${QEMU_SHA:?需设置定制版QEMU sha256}"
ORIG_SHA="${ORIG_SHA:?需设置原版QEMU sha256}"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "════ 层0: 原版镜像身份 ════"
OMD5=$(md5sum "$ORIGGZ" | cut -d' ' -f1)
echo "  原版 md5=$OMD5（与官方分发记录人工核对）"

echo "════ 层1: 定制版归档完整性 ════"
if gzip -t "$PATGZ" 2>/dev/null; then ok "gzip CRC 全归档校验"; else bad "gzip CRC 校验失败"; fi
SIZE=$(stat -c%s "$PATGZ"); MD5=$(md5sum "$PATGZ" | cut -d' ' -f1)
echo "  大小=$SIZE  md5=$MD5"
[ "$SIZE" = "$SIZE_EXPECT" ] && ok "大小与记录一致" || bad "大小与记录不符"
[ "$MD5" = "$MD5_EXPECT" ]   && ok "md5 与记录一致"   || bad "md5 与记录不符"

echo "════ 层2: 解压两镜像 + GPT ════"
gzip -dc "$ORIGGZ" > /opt/v_orig.img
gzip -dc "$PATGZ" > /opt/v_pat.img
LO=$(losetup -fP -r --show /opt/v_orig.img)
LP=$(losetup -fP -r --show /opt/v_pat.img)
for L in "$LO" "$LP"; do
    GPTOK=$(python3 - "$L" <<'EOF'
import struct, sys
f = open(sys.argv[1], 'rb')
f.seek(512); hdr = f.read(512)
if hdr[:8] != b'EFI PART': print('BAD'); raise SystemExit
n = struct.unpack_from('<I', hdr, 80)[0]
f.seek(struct.unpack_from('<Q', hdr, 72)[0] * 512)
cnt = sum(1 for i in range(n) if f.read(128)[0:16] != b'\x00' * 16)
print('OK' if cnt >= 1 else 'BAD')
EOF
)
    [ "$GPTOK" = "OK" ] && ok "GPT 分区表完整" || bad "GPT 结构异常"
done

echo "════ 层3: ext4 只读全检 e2fsck -fn ════"
e2fsck -fn "${LP}p1" > /tmp/e2fsck.log 2>&1
E2RC=$?; tail -1 /tmp/e2fsck.log
ERRWORDS=$(grep -ciE 'error|corrupt|bad' /tmp/e2fsck.log)
if [ "$E2RC" = "0" ] && [ "$ERRWORDS" = "0" ]; then ok "e2fsck 干净"; else bad "e2fsck 退出码=$E2RC 错误字样=$ERRWORDS"; fi

echo "════ 层4: 与原版逐字节对照 ════"
mkdir -p /mnt/osimg_o /mnt/osimg
mount -o ro "${LO}p1" /mnt/osimg_o
mount -o ro "${LP}p1" /mnt/osimg
MO=/mnt/osimg_o; M=/mnt/osimg

for f in boot/vmlinuz boot/initrd etc/fstab EDK2固件; do :; done
# 引导链关键文件（名称按实际镜像核对，默认值对应本方案 v1.0.9）
for f in "$M"/boot/*vmlinuz*; do
    rel=${f#$M/}
    cmp -s "$f" "$MO/$rel" && ok "$rel 与原版一致" || bad "$rel 不一致"
done
for f in "$M"/boot/*initrd*; do
    rel=${f#$M/}
    cmp -s "$f" "$MO/$rel" && ok "$rel 与原版一致" || bad "$rel 不一致"
done
cmp -s "$M/etc/fstab" "$MO/etc/fstab" && ok "fstab 与原版一致（出厂态）" || bad "fstab 被改动"
[ -f "$MO/mnt/*/QEMU_EFI.fd" ] 2>/dev/null
cmp -s "$M"/mnt/*/QEMU_EFI.fd "$MO"/mnt/*/QEMU_EFI.fd && ok "EDK2 固件未被动过" || bad "固件被改"

QH=$(sha256sum "$M${QEMU_PATH:-/usr/local/bin/qemu-system-aarch64}" | cut -d' ' -f1)
[ "$QH" = "$QEMU_SHA" ] && ok "QEMU = 定制版哈希" || bad "QEMU 哈希异常: $QH"
OH=$(sha256sum "$M${QEMU_PATH:-/usr/local/bin/qemu-system-aarch64}.orig" | cut -d' ' -f1)
[ "$OH" = "$ORIG_SHA" ] && ok "QEMU.orig = 原版哈希（回退通道完好）" || bad "QEMU.orig 哈希异常: $OH"

for f in import-template.sh attach-usb.py vm-autostart.sh; do
    cmp -s "$M/opt/win-vm/$f" "$KIT/$f" && ok "套件 $f 一致" || bad "套件 $f 不一致"
done

echo "════ 层5: 服务状态 ════"
W=$(readlink "$M/etc/systemd/system/multi-user.target.wants/windows-vm.service" 2>/dev/null)
[ "$W" = "../windows-vm.service" ] && ok "windows-vm 自启动已启用" || bad "自启动未启用"
for u in "$M"/etc/systemd/system/*.service; do
    case "$(basename "$u")" in
        windows-vm.service*) ;;
        *.bak) ;;
        *)  [ -L "$u" ] && [ "$(readlink "$u")" = "/dev/null" ] && ok "$(basename "$u") 已屏蔽（保留 .bak 可恢复）" ;;
    esac
done

echo "════ 层5.5: 隐私加固 ════"
HITS=$(grep -c '127.0.0.1' "$M/etc/hosts" 2>/dev/null)
[ "${HITS:-0}" -ge 1 ] && ok "hosts 含阻断条目" || bad "hosts 无阻断条目"
LOGS=$(find "$M/mnt" -name '*.log' -size +0 -type f 2>/dev/null | wc -l)
[ "$LOGS" = "0" ] && ok "镜像内业务日志已清空" || bad "$LOGS 个日志未清空"

echo "════ 层6: 定制点动态对照 ════"
qemu-aarch64 -L "$M" "$M${QEMU_PATH:-/usr/local/bin/qemu-system-aarch64}" --version >/dev/null 2>&1
[ $? = 0 ] && ok "定制版 QEMU 可执行" || bad "QEMU 无法执行"
timeout 60 qemu-aarch64 -L "$M" "$M${QEMU_PATH:-/usr/local/bin/qemu-system-aarch64}" \
    -machine virt,accel=tcg -m 512 -bios "$M"/mnt/*/QEMU_EFI.fd -display none >/dev/null 2>&1
RC=$?
timeout 60 qemu-aarch64 -L "$MO" "$MO${QEMU_PATH:-/usr/local/bin/qemu-system-aarch64}" \
    -machine virt,accel=tcg -m 512 -bios "$MO"/mnt/*/QEMU_EFI.fd -display none >/dev/null 2>&1
RC2=$?
echo "  定制版 rc=$RC / 原版 rc=$RC2（定制版不应与原版同为同一退出码；原版应有专属退出码作为对照）"
[ "$RC" != "$RC2" ] && ok "两镜像行为出现预期分化" || bad "两镜像行为未分化，需人工检查"

umount /mnt/osimg /mnt/osimg_o
losetup -d "$LO" "$LP"
rm -f /opt/v_orig.img /opt/v_pat.img

echo "══════════════════════════════"
echo "终检结果: 通过 $PASS 项, 失败 $FAIL 项"
[ $FAIL -eq 0 ] && echo "FINAL_VERDICT: ALL_PASS" || echo "FINAL_VERDICT: HAS_FAILURES"
