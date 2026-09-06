#!/bin/bash
# =============================================================================
# repatch-official.sh —— 官方新版镜像 → 定制版镜像 的一键流水线
#
# 用法: repatch-official.sh <新版官方镜像.gz> [输出目录]
#
# 流程:
#   解压官方 gz → 提取宿主内 QEMU → generic-patch-qemu.py 单指令定制补丁
#   → 换入补丁版 QEMU（原版留 .orig）→ 安装部署套件（vm-autostart 等）
#   → 屏蔽宿主管理服务（保留 .bak 可恢复）→ privacy-hardening.sh 隐私加固
#   → 重打包 → 输出 <原名>-patched.img.gz 与 md5
#
# 依赖: WSL/Linux + losetup + python3(capstone) + pigz（可选加速）
# =============================================================================
set -e
NEWGZ="$1"
OUTDIR="${2:-$(pwd)}"
REPO="$(cd "$(dirname "$0")" && pwd)"
BASE=$(basename "$NEWGZ" .img.gz)
MGR_SVC="${MGR_SVC:-thin-idv}"            # 宿主管理服务名（按实际镜像调整）
DAEMON_DIR="${DAEMON_DIR:-/opt/thin-daemon}"  # 宿主启动脚本所在目录
QEMU_PATH="${QEMU_PATH:-/usr/local/bin/qemu-system-aarch64}"

[ -f "$NEWGZ" ] || { echo "用法: $0 <新版官方镜像.gz> [输出目录]"; exit 1; }

echo "== 1. 解压 =="
gzip -dc "$NEWGZ" > /opt/rp.img
L=$(losetup -fP --show /opt/rp.img)
mkdir -p /mnt/osimg
mount ${L}p1 /mnt/osimg
M=/mnt/osimg

echo "== 2. QEMU 单指令定制补丁 =="
cp "$M${QEMU_PATH}" /tmp/qemu_vendor
python3 "$REPO/generic-patch-qemu.py" /tmp/qemu_vendor /tmp/qemu_patched
mv "$M${QEMU_PATH}" "$M${QEMU_PATH}.orig"
cp /tmp/qemu_patched "$M${QEMU_PATH}"
chmod 755 "$M${QEMU_PATH}" "$M${QEMU_PATH}.orig"

echo "== 3. 安装部署套件 =="
mkdir -p "$M/opt/win-vm"
cp "$REPO/import-template.sh" "$REPO/attach-usb.py" "$REPO/vm-autostart.sh" "$M/opt/win-vm/"
chmod 755 "$M/opt/win-vm/"*
cp "$REPO/../examples/windows-vm.service" "$M/etc/systemd/system/windows-vm.service"

echo "== 4. 屏蔽宿主管理服务（保留 .bak 可恢复）=="
for u in "$MGR_SVC" "$MGR_SVC-server"; do
    if [ -f "$M/etc/systemd/system/$u.service" ] && [ ! -L "$M/etc/systemd/system/$u.service" ]; then
        mv "$M/etc/systemd/system/$u.service" "$M/etc/systemd/system/$u.service.bak"
    fi
    ln -sf /dev/null "$M/etc/systemd/system/$u.service"
done
mkdir -p "$M/etc/systemd/system/multi-user.target.wants"
ln -sf ../windows-vm.service "$M/etc/systemd/system/multi-user.target.wants/windows-vm.service"

echo "== 5. 隐私加固 =="
bash "$REPO/privacy-hardening.sh" "$M"
sync

umount /mnt/osimg
losetup -d "$L"

echo "== 6. 重打包 =="
command -v pigz >/dev/null 2>&1 || apt-get install -y -qq pigz >/dev/null 2>&1 || true
if command -v pigz >/dev/null 2>&1; then
    pigz -6 -f -k /opt/rp.img && mv -f /opt/rp.img.gz "$OUTDIR/${BASE}-patched.img.gz"
else
    gzip -6 -c /opt/rp.img > "$OUTDIR/${BASE}-patched.img.gz"
fi
rm -f /opt/rp.img /tmp/qemu_vendor /tmp/qemu_patched
OUT="$OUTDIR/${BASE}-patched.img.gz"
echo "== 完成: $OUT =="
md5sum "$OUT"
echo "下一步: 用 final-verify.sh 做完整性终检（更新其中的哈希记录后运行）"
