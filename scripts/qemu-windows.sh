#!/bin/bash
# =============================================================================
# qemu-windows.sh —— Windows 11 ARM 虚机启动参考实现（KVM + virtio 标准设备）
#
# 用法: qemu-windows.sh [VMID] [PERSISTENT] [BOOT_INDEX] [RESCUE_MODE]
#   VMID        虚拟盘标识（$VHD_DIR/$VMID/），默认 win11-local
#   PERSISTENT  1=持久  0=非持久（qcow2 快照，重启还原）
#   BOOT_INDEX  盘编号后缀，默认 1
#   RESCUE_MODE 1=救援模式（ramfb 显示 + ramfb 固件）
#
# 可用环境变量:
#   VHD_DIR       虚拟盘根目录（默认 /srv/idv/vhd）
#   QEMU_BIN      qemu-system-aarch64 路径（默认取 /usr/bin）
#   EFI_FILE      虚机 UEFI 固件（EDK2 ArmVirtQemu 构建，默认 /srv/idv/QEMU_EFI.fd）
#   RESOLUTION_X/Y 虚机分辨率（默认 1920x1080）
#   LINK_SHUTDOWN 1 = Windows 关机后联动关闭宿主（默认 1）
#   EXTRA_USB     "bus:addr bus:addr ..." 启动时直通的 USB 设备
# =============================================================================
VMID="${1:-win11-local}"
PERSISTENT="${2:-1}"
BOOT_INDEX="${3:-1}"
RESCUE_MODE="${4:-0}"

QEMU_BIN="${QEMU_BIN:-/usr/bin/qemu-system-aarch64}"
VHD_DIR="${VHD_DIR:-/srv/idv/vhd}"
EFI_FILE="${EFI_FILE:-/srv/idv/QEMU_EFI.fd}"
EFI_RAMFB="${EFI_RAMFB:-/srv/idv/QEMU_EFI_ramfb.fd}"
LOG="${WINVM_LOG:-/var/log/win-vm.log}"
RESOLUTION_X="${RESOLUTION_X:-1920}"
RESOLUTION_Y="${RESOLUTION_Y:-1080}"

my_echo() { echo "$(date +'%F %T') : $1" >> "$LOG"; }

[ -e /dev/kvm ] || { echo "错误：/dev/kvm 不存在（需要本平台定制内核的 KVM）" >&2; exit 1; }
command -v "$QEMU_BIN" >/dev/null || { echo "错误：未找到 $QEMU_BIN" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "错误：缺少 qemu-img" >&2; exit 1; }

# ---- 显示设备探测：virtio-ramfb 不可用则回退 virtio-gpu-pci ----
if [ "$RESCUE_MODE" = "1" ]; then
    DISPLAY_DEV="ramfb"
    EFI_FILE="$EFI_RAMFB"
elif "$QEMU_BIN" -device help 2>/dev/null | grep -q virtio-ramfb; then
    DISPLAY_DEV="virtio-ramfb,xres=$RESOLUTION_X,yres=$RESOLUTION_Y"
else
    DISPLAY_DEV="virtio-gpu-pci,xres=$RESOLUTION_X,yres=$RESOLUTION_Y"
fi

# ---- 虚拟盘：持久直用；非持久 qcow2 快照 ----
BASE_DISK="$VHD_DIR/$VMID/vm-$VMID-$BOOT_INDEX.qcow2"
[ -f "$BASE_DISK" ] || BASE_DISK="$VHD_DIR/$VMID/vm-$VMID-$BOOT_INDEX.img"
[ -f "$BASE_DISK" ] || { echo "错误：找不到虚拟盘 $VHD_DIR/$VMID/，先运行 import-template.sh" >&2; exit 1; }

if [ "$PERSISTENT" = "1" ]; then
    IMG_FILE="$BASE_DISK"
else
    mkdir -p "$VHD_DIR/$VMID"
    rm -f "$VHD_DIR/$VMID/vm-$VMID-snapshot.qcow2"
    qemu-img create -f qcow2 -b "$BASE_DISK" "$VHD_DIR/$VMID/vm-$VMID-snapshot.qcow2" >/dev/null
    IMG_FILE="$VHD_DIR/$VMID/vm-$VMID-snapshot.qcow2"
fi

# ---- 内存分档 ----
total_mem=$(free | awk '/^Mem:/ {print $2}')
VM_MEMORY=2048
if   (( total_mem >  30720 * 1024 )); then VM_MEMORY=30720
elif (( total_mem >  20480 * 1024 )); then VM_MEMORY=20480
elif (( total_mem >  14336 * 1024 )); then VM_MEMORY=14336
elif (( total_mem >  12288 * 1024 )); then VM_MEMORY=12288
elif (( total_mem >   8192 * 1024 )); then VM_MEMORY=8192
elif (( total_mem >   6144 * 1024 )); then VM_MEMORY=6144
elif (( total_mem >   4096 * 1024 )); then VM_MEMORY=4096
fi

# ---- vCPU = 物理核数（SMT 兄弟算 1 核）----
CORE_FILE=$(mktemp)
for t in /sys/devices/system/cpu/cpu[0-9]*/topology; do
    [ -f "$t/thread_siblings_list" ] && cat "$t/thread_siblings_list" >> "$CORE_FILE"
done
CORES=$(sort -u "$CORE_FILE" | grep -c .); rm -f "$CORE_FILE"
VM_CORES=$(( CORES > 0 ? CORES : 4 ))

# ---- MAC 持久化 ----
MAC_FILE="${MAC_FILE:-$VHD_DIR/vm_mac_addr}"
VM_MAC=$(cat "$MAC_FILE" 2>/dev/null)
if [ -z "$VM_MAC" ]; then
    VM_MAC="88:$(od /dev/urandom -w5 -tx1 -N5 -An 2>/dev/null | tr -d ' \n' | sed 's/../&:/g;s/:$//')"
    mkdir -p "$(dirname "$MAC_FILE")"; echo "$VM_MAC" > "$MAC_FILE"
fi

# ---- CPU 性能模式 ----
for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    [ -e "$p" ] && echo performance > "$p" 2>/dev/null
done

# ---- Wayland 环境（SDL 全屏窗口落在 weston 上）----
export WAYLAND_DISPLAY=wayland-0
export SDL_VIDEODRIVER=wayland
export XDG_SESSION_TYPE=wayland
export XDG_RUNTIME_DIR=/run/user/0/

QMP_DIR="${QMP_DIR:-/var/run/win-vm}"
mkdir -p "$QMP_DIR"
sysctl -w net.ipv4.ping_group_range='0 2147483647' >/dev/null 2>&1

# ---- USB 直通（启动时静态直通；运行中热插拔见 attach-usb.py）----
USB_ARGS=""
for pair in $EXTRA_USB; do
    bus="${pair%%:*}"; addr="${pair##*:}"
    USB_ARGS+=" -device usb-host,hostbus=$bus,hostaddr=$addr"
done

# ---- 组装命令 ----
CMD="$QEMU_BIN -name win11-vm,debug-threads=on \
 -machine virt,accel=kvm,usb=off,dump-guest-core=off,gic-version=3 \
 -cpu host -smp $VM_CORES -m $VM_MEMORY \
 -bios $EFI_FILE \
 -boot menu=on,strict=on -k en-us \
 -drive file=$IMG_FILE,if=none,id=drive-virtio0,cache=writeback,aio=threads,werror=stop,rerror=stop,l2-cache-size=13107200 \
 -device virtio-blk-pci,scsi=off,drive=drive-virtio0,id=virtio0-0,write-cache=off,physical_block_size=4096,logical_block_size=512,bootindex=100 \
 -device $DISPLAY_DEV \
 -device qemu-xhci,p2=8,p3=8,id=usb,streams=off \
 -device usb-kbd,id=input0 -device usb-tablet -device virtio-tablet-pci,id=input2 \
 -rtc base=localtime,clock=rt \
 -netdev user,id=n1,net=10.0.0.0/24,host=10.0.0.1,hostfwd=tcp::8022-:22,hostfwd=tcp::3389-:3389,ipv6=off \
 -device virtio-net-pci,netdev=n1,mac=$VM_MAC \
 -display sdl -full-screen -daemonize \
 -device pvpanic-pci \
 -qmp unix:$QMP_DIR/$VMID.qmp,server=on,wait=off \
 $USB_ARGS"

my_echo "$CMD"
$CMD >> "$LOG" 2>&1
QEMU_RC=$?
[ $QEMU_RC -ne 0 ] && { my_echo "qemu 启动失败 rc=$QEMU_RC"; exit $QEMU_RC; }
my_echo "qemu 启动成功"

# ---- 关机联动：Windows 内关机 → QEMU 退出 → 整机关机（可选）----
if [ "${LINK_SHUTDOWN:-1}" = "1" ] && [ -f "$VHD_DIR/link_shutdown" ]; then
    while ps aux | grep -v grep | grep -q qemu-system-aarch64; do sleep 1; done
    my_echo "虚机退出，联动关机"
    poweroff
fi
