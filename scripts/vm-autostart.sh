#!/bin/bash
# =============================================================================
# vm-autostart.sh —— 宿主镜像内部的开机自启动包装脚本
# （此脚本在宿主镜像内运行；路径为该镜像内的实际布局，可通过环境变量覆盖）
#
# 逻辑：首次开机若无已导入虚拟盘，则按 /etc/new_template.json 自动导入模板；
#       随后调用宿主自带的虚机启动脚本，全屏进入 Windows。
# =============================================================================
LOG="${WINVM_LOG:-/var/log/win-vm-autostart.log}"
VMID="${VMID:-win11-local}"
RUN_QEMU="${RUN_QEMU:-/opt/thin-daemon/run_qemu.sh}"      # 宿主自带的虚机启动脚本
THINIMG="${THINIMG_DIR:-/mnt/thinimg}"                    # 宿主的虚机资源根目录
DISK1="$THINIMG/vhd/$VMID/vm-$VMID-1.qcow2"
DISK2="$THINIMG/vhd/$VMID/vm-$VMID-1.img"
exec >> "$LOG" 2>&1
echo "=== win-vm autostart $(date) ==="

if [ ! -f "$DISK1" ] && [ ! -f "$DISK2" ]; then
    echo "未发现已导入虚拟盘，按 /etc/new_template.json 自动导入模板..."
    if [ ! -f /etc/new_template.json ]; then
        echo "错误：/etc/new_template.json 不存在（请手动运行 import-template.sh）"
        exit 1
    fi
    TP=$(python3 -c 'import json;print(json.load(open("/etc/new_template.json")).get("template_path",""))' 2>/dev/null)
    PUUID=$(python3 -c 'import json;print(json.load(open("/etc/new_template.json")).get("partition_uuid",""))' 2>/dev/null)
    if [ -z "$TP" ]; then
        echo "错误：new_template.json 中无 template_path"
        exit 1
    fi
    # 显式按 UUID 挂载模板所在分区（与 fstab 双保险）
    if [ -n "$PUUID" ]; then
        mkdir -p /mnt/partition_contains_template
        mount UUID="$PUUID" /mnt/partition_contains_template 2>/dev/null || true
    fi
    SRC="/mnt/partition_contains_template$TP"
    if [ -d "$SRC" ]; then
        SRC=$(find "$SRC" -maxdepth 2 -name '*.tar.gz' 2>/dev/null | head -1)
    fi
    if [ ! -f "$SRC" ]; then
        echo "错误：模板文件不存在: new_template.json=$TP（分区=$PUUID）"
        exit 1
    fi
    echo "导入模板: $SRC"
    /opt/win-vm/import-template.sh "$SRC" "$VMID" || exit 1
fi

echo "启动 Windows 虚机（VMID=$VMID）..."
exec "$RUN_QEMU" "$VMID" 1 1 0 0
