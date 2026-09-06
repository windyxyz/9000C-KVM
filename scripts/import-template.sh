#!/bin/bash
# =============================================================================
# import-template.sh —— 把 Windows 模板（tar.gz）导入为可启动的 qcow2 虚拟盘
#
# 用法: import-template.sh <windows11-xxx.tar.gz> [VMID]
#   VMID 默认 win11-local
#   产物: $VHD_DIR/<VMID>/vm-<VMID>-1.qcow2（持久盘，BOOT_INDEX=1）
#
# 可用环境变量:
#   VHD_DIR   虚拟盘根目录（默认 /srv/idv/vhd，按宿主布局调整）
#   FORCE_RAW 1 = 跳过 qcow2 转换直接使用 raw（空间紧张时）
# =============================================================================
set -e

SRC="$1"
VMID="${2:-win11-local}"
VHD_DIR="${VHD_DIR:-/srv/idv/vhd}"
STAGE="$VHD_DIR/temp-import-$VMID"
OUT_DIR="$VHD_DIR/$VMID"
LOG="${WINVM_LOG:-/var/log/win-vm.log}"

[ -f "$SRC" ] || { echo "用法: $0 <windows11-xxx.tar.gz> [VMID]"; exit 1; }
log() { echo "$(date +'%F %T') $1" | tee -a "$LOG"; }

free_kb=$(df -kP "$(dirname "$STAGE")" | tail -1 | awk '{print $4}')
log "导入开始: $SRC -> VMID=$VMID (可用 $((free_kb/1024/1024)) GB)"

mkdir -p "$OUT_DIR" "$STAGE/extract"
trap 'rm -rf "$STAGE"' EXIT

log "解包模板（较大，耐心等待）..."
if command -v pigz >/dev/null; then
    tar -I pigz -xf "$SRC" -C "$STAGE/extract"
else
    tar -xzf "$SRC" -C "$STAGE/extract"
fi

DISK_FILE=$(find "$STAGE/extract" -type f -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$DISK_FILE" ] || { log "错误：tar 包中未找到文件"; exit 1; }
log "识别到磁盘文件: $DISK_FILE ($(du -h "$DISK_FILE" | cut -f1))"

INFO=$(qemu-img info --output=json "$DISK_FILE")
FMT=$(echo "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format","raw"))')
VSIZE=$(echo "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",0))')
log "格式=$FMT 虚拟大小=$VSIZE"

if [ "$FMT" = "qcow2" ]; then
    cp -a "$DISK_FILE" "$OUT_DIR/vm-$VMID-1.qcow2"
    log "qcow2 模板直接就位"
elif [ "${FORCE_RAW:-0}" = "1" ] || [ "$free_kb" -le $(( VSIZE * 22 / 10 / 1024 )) ]; then
    log "空间不足或 FORCE_RAW=1，直接使用 raw 盘（功能等价，占满虚拟大小）"
    mv "$DISK_FILE" "$OUT_DIR/vm-$VMID-1.img"
else
    log "转换为 qcow2（持久、按需占用）..."
    qemu-img convert -p -f "$FMT" -O qcow2 "$DISK_FILE" "$OUT_DIR/vm-$VMID-1.qcow2"
fi

qemu-img info "$OUT_DIR"/vm-"$VMID"-1.* | head -6
log "导入完成: 启动方式 qemu-windows.sh $VMID 1 1 0"
