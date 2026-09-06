# 9000C KVM

在 9000C（Kirin 9000C / ARM64 终端硬件）上通过 **KVM 硬件虚拟化**运行 Windows 11 ARM64 的学习研究项目。

> ⚠️ **免责声明**
>
> - 本项目**仅供学习研究**使用，用于理解 ARM 终端上的桌面虚拟化（IDV）架构与 KVM 引导实现；
> - 请勿用于任何商业或生产用途；
> - 仓库**不含任何专有二进制文件**（系统镜像、QEMU 定制构建、Windows 模板等均不在仓库内），
>   仅包含架构文档、参考脚本与部署教程；
> - Windows 与相关组件的授权由使用者自行解决，与本项目无关。

## 这是什么

一类典型的 **IDV（Intelligent Desktop Virtualization，智能桌面虚拟化）** 终端方案：

```
┌─────────────────────────────────────────────────────────┐
│  9000C 终端硬件（Kirin 9000C，ARM64）                     │
│                                                         │
│  UEFI 固件                                              │
│    └─ GRUB 双菜单 ──► ① 原生系统（UOS/麒麟，日常保留）     │
│                    └─ ② IDV 宿主系统（openEuler 底座）    │
│                           ├─ weston (Wayland)            │
│                           ├─ 定制内核（提供 /dev/kvm）    │
│                           └─ QEMU/KVM ──► Windows 11 ARM │
│                                ├─ virtio-blk  系统盘      │
│                                ├─ virtio-net  网络        │
│                                ├─ virtio-gpu  显示        │
│                                ├─ qemu-xhci   USB 直通    │
│                                └─ EDK2 ArmVirtQemu 固件   │
└─────────────────────────────────────────────────────────┘
```

Windows 在这里**真实引导内核**（不是模拟器、不是兼容层）：KVM 走 ARM 硬件虚拟化（EL2），
`-cpu host` 直通宿主 CPU，Win11 ARM 通过 EDK2 虚拟 UEFI 正常启动，性能接近原生。

## 仓库结构

```
docs/
  01-架构总览.md          整机方案与引导链全景
  02-部署教程.md          从宿主镜像到全屏 Windows 的完整部署流程
  03-虚拟设备与性能.md     virtio 设备、两层设备模型、性能优化与 GPU 现状
  04-镜像与模板管理.md     Windows 模板导入、持久/非持久快照、数据盘
scripts/
  import-template.sh          Windows 模板（tar.gz）→ qcow2 虚拟盘
  qemu-windows.sh             QEMU 启动参考实现（标准设备）
  attach-usb.py               运行中的虚机热插拔 USB 设备（QMP）
  vm-autostart.sh             宿主镜像内的开机自启动包装（首次自动导入模板）
  repatch-official.sh         官方新版镜像 → 定制版镜像 的一键流水线
  privacy-hardening.sh        宿主镜像隐私加固（域名阻断/配置失效化/日志清理）
  generic-patch-qemu.py       QEMU 单指令定制补丁器（跨版本通用定位）
  installer-telemetry-patch.py 安装器 deb 遥测移除补丁
  final-verify.sh             定制版镜像出厂终检（30 项对照清单）
examples/
  windows-vm.service          开机自动进 Windows 的 systemd 单元
  grub-file-image.conf        "文件镜像引导" GRUB 菜单项示例
```

## 核心技术点

1. **文件镜像引导**：整个 Linux 宿主根文件系统是一个磁盘镜像文件（os.img），
   由专用 initrd 在内核参数（分区 UUID + 路径）指引下 loop 挂载后切换根——
   宿主系统可以像普通文件一样存放在已有分区的目录里。
2. **KVM on ARM**：麒麟 9000C 平台的 KVM 支持依赖为该平台定制的内核；
   `/dev/kvm` 存在即代表虚拟化可用。
3. **virtio 半虚拟化**：磁盘/网卡/显卡/输入全部走 virtio，这是性能上限最高的设备模型。
4. **EDK2 ArmVirtQemu**：Windows 侧使用开源 Tianocore 的 ARM 虚拟机固件，无需定制。
5. **快照即还原**：持久虚机直接用基础盘；非持久虚机用 `qemu-img create -b` 生成
   写时复制快照，重启即还原，适合批量终端场景。

## 快速开始

见 [docs/02-部署教程.md](docs/02-部署教程.md)。

## 开发与接手

官方出新版镜像后的重打流水线、定制补丁原理、验证方法论、交付物清单：
见 [docs/05-开发与接手指南.md](docs/05-开发与接手指南.md)。

## 声明

文档与参考脚本按 "AS-IS" 提供，仅用于学习研究；不含任何专有二进制。
