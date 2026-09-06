#!/usr/bin/env python3
"""
attach-usb.py —— 通过 QMP 向运行中的 Windows 虚机热插拔 USB 设备

用法:
  attach-usb.py list                    列出宿主 USB 设备（标注可直通项）
  attach-usb.py add <bus> <addr> [名]   把指定设备接入虚机
  attach-usb.py del <设备id>            从虚机移除

原理: 连接 QEMU 的 QMP unix socket（/var/run/win-vm/<VMID>.qmp），
      device_add/del usb-host（标准 QEMU 设备，需显式 bus/addr）。
"""
import json, socket, sys, subprocess, glob, os

VMID = sys.argv[4] if len(sys.argv) > 4 else os.environ.get("VMID", "win11-local")
QMP = os.environ.get("QMP_SOCK", f"/var/run/win-vm/{VMID}.qmp")

# 直通黑名单：默认跳过音频(01)/打印(07)/视频(ef)类设备，避免占用宿主键鼠麦克风
DENY_DEVICE_CLASS = {"01", "07", "ef"}
DENY_VID_PID = set()


def lsusb_devices():
    out = subprocess.run(["lsusb"], capture_output=True, text=True).stdout
    devs = []
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 6 and ":" in p[5]:
            bus, addr = int(p[1]), int(p[3].rstrip(":"))
            devs.append({"bus": bus, "addr": addr,
                         "vidpid": p[5], "name": " ".join(p[6:]) or p[5]})
    return devs


def denied(d):
    if d["vidpid"] in DENY_VID_PID:
        return True
    base = f"/sys/bus/usb/devices/{d['bus']}-{d['addr']}"
    try:
        with open(f"{base}/bDeviceClass") as f:
            if f.read().strip() in DENY_DEVICE_CLASS:
                return True
    except OSError:
        pass
    return False


def qmp(*commands):
    s = socket.socket(socket.AF_UNIX)
    s.connect(QMP)
    f = s.makefile("rw")
    json.loads(f.readline())                                   # greeting
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
    json.loads(f.readline())
    for cmd in commands:
        f.write(json.dumps(cmd) + "\n"); f.flush()
        while True:
            resp = json.loads(f.readline())
            if "return" in resp or "error" in resp:
                print(json.dumps(resp, ensure_ascii=False))
                break


def main():
    if not glob.glob(QMP):
        sys.exit(f"QMP socket 不存在: {QMP}（虚机未启动？）")
    op = sys.argv[1] if len(sys.argv) > 1 else "list"

    if op == "list":
        for i, d in enumerate(lsusb_devices()):
            hint = " [跳过:黑名单/音视频类]" if denied(d) else \
                   f"  <- 直通: attach-usb.py add {d['bus']} {d['addr']}"
            print(f"{i}: Bus {d['bus']:03d} Addr {d['addr']:03d} {d['vidpid']} {d['name']}{hint}")
    elif op == "add":
        bus, addr = sys.argv[2], sys.argv[3]
        name = sys.argv[4] if len(sys.argv) > 4 else f"usbhost{bus}_{addr}"
        qmp({"execute": "device_add", "arguments": {
            "driver": "usb-host", "id": name,
            "hostbus": str(bus), "hostaddr": str(addr)}})
        print(f"已接入: {name} (bus={bus} addr={addr})；移除: attach-usb.py del {name}")
    elif op == "del":
        qmp({"execute": "device_del", "arguments": {"id": sys.argv[2]}})
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
