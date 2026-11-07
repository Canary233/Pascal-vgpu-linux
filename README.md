# Pascal-vgpu-linux

在 **Proxmox VE 9 / Linux 7.0 内核**上为 **NVIDIA Pascal 消费卡**（P106-100、P104-100、GTX 10xx 等）
启用 **vGPU** 的一键部署方案。

> 官方 vGPU 只支持认证卡，且 vGPU 17.0 起移除 Pascal 支持；本项目的做法是
> **vGPU 16.5 宿主驱动（535.161.05）+ 消费卡解锁补丁 + 针对 Linux 7.0 的内核移植补丁**，
> 把这张"矿卡"变成能被多台虚拟机共享的 vGPU 设备。

## 已验证环境

| 项 | 值 |
|---|---|
| 系统 | Debian 13 / Proxmox VE 9.2.26 |
| 内核 | `7.0.14-28-pve`（6.8 / 6.1x 亦可，补丁对低版本自动失效） |
| 显卡 | NVIDIA **P106-100**（GP106，`10de:1c07`，6GB，无显示输出） |
| 驱动 | vGPU 宿主驱动 **535.161.05**（vGPU 16.5） |
| 客户机 | Windows 10（OVMF + q35 + virtio-scsi） |
| 结果 | 20 个 vGPU profile，mdev 实例创建/挂载/运行正常 |

## 它解决了什么问题

直接拿 535 驱动上 7.0 内核会撞上三类问题，本项目都已处理（见 `patches/`）：

1. **消费卡不被 vGPU 认可** —— 用 `polloloco/vgpu-proxmox` 的二进制补丁恢复 Pascal 消费卡的 vGPU 能力。
2. **设备白名单校验** —— 用 `vgpu_unlock-rs` 在 `nvidia-vgpud` / `nvidia-vgpu-mgr` 启动时注入，
   让 RM 把 P106 当成受支持的卡（默认 spoof 成 GRID P40）。
3. **7.0 内核 API 变动** —— 12 个文件的移植补丁，主要几处：
   - 7.0 的 `KBUILD_CFLAGS` 增加 `-fms-extensions`（`struct filename` 用匿名 struct 成员），
     驱动自带的 conftest 探测缺这个标志，导致 **几乎所有特性探测失效**
   - `vm_area_struct.vm_flags` 变 `const`，且 `vm_flags_set()` 引用了 **GPL-only** 符号
     （nvidia.ko 非 GPL 许可，用不了）→ 改用无锁的 `__vm_flags_mod()`
   - `follow_pfn()` 移除，替代者 `follow_pfnmap_*` 同样是 GPL-only → 自实现只读页表遍历
   - vfio 核心不再把 `VFIO_DEVICE_GET_REGION_INFO` 转给驱动的 `.ioctl`，
     改由 `get_region_info_caps` 回调提供 → 新增该回调
   - `irq_bypass` API、`iommu_fwspec`、`dma_map_ops::map_resource`、`del_timer_sync`、
     `in_irq`、`no_llseek`、`MODULE_IMPORT_NS` 等零散适配
   - **APICV 路径在 7.0 上被编译剔除**（`enable_apicv` 位于 KVM 的 `module:` 命名空间，
     modpost 禁止外部模块导入）；vGPU 仍走常规 irqfd，功能不受影响，仅少 posted-interrupt 加速

## 前置条件

- Proxmox VE 9（Debian 13），x86_64
- 内核 **IOMMU 已启用**：`/proc/cmdline` 里有 `intel_iommu=on`（或 `amd_iommu=on`），
  通常还要加 `iommu=pt`
- 显卡未被 vfio-pci 占用（如果之前做过 PCI 直通，先还原）
- Secure Boot **关闭**（未签名内核模块无法加载；本项目验证时机器处于 Setup Mode）
- 磁盘 ≥ 3GB 空闲（驱动包 + 源码树 + 构建产物）

## 快速开始（PVE 宿主机一键部署）

```bash
git clone https://github.com/Canary233/Pascal-vgpu-linux.git
cd Pascal-vgpu-linux
sudo bash scripts/deploy-pve.sh
```

脚本会依次完成：

1. 环境检查（PVE / 内核 / IOMMU / Pascal 设备）
2. 安装依赖（内核头文件、dkms、gcc、cargo 等）
3. 下载 vGPU 16.5 宿主驱动并校验 MD5
4. 打 polloloco 消费卡解锁补丁 + 本项目 7.0 移植补丁
5. 安装用户态（`nvidia-vgpud` / `nvidia-vgpu-mgr` / `vgpuConfig.xml`）
6. 注册 DKMS 并构建 `nvidia.ko` / `nvidia-vgpu-vfio.ko`
7. 编译并安装 `vgpu_unlock-rs`（**不用** PVE-Tools 那个损坏的预编译库）
8. 写系统配置（屏蔽 nouveau、模块开机加载、vfio）
9. 启动服务并验证 mdev 类型

常用参数：

```bash
sudo bash scripts/deploy-pve.sh --dry-run          # 只检查环境、打印计划
sudo bash scripts/deploy-pve.sh --yes              # 全自动，无交互
sudo bash scripts/deploy-pve.sh --driver /root/NVIDIA-Linux-x86_64-535.161.05-vgpu-kvm.run
sudo bash scripts/deploy-pve.sh --with-license 4444  # 顺带部署 license server
sudo bash scripts/deploy-pve.sh --uninstall        # 卸载
```

> 驱动本体受 NVIDIA 许可限制，**不随仓库分发**。脚本默认从社区镜像下载（含 MD5 校验），
> 也可以自己拿到 `.run` 后用 `--driver` 指定。

### 验证部署

```bash
# 驱动是否接管显卡
lspci -k -s 01:00.0 | grep 'in use'      # 期望：Kernel driver in use: nvidia

# 服务状态（vgpud 是 oneshot，inactive 属正常，看退出码）
systemctl show nvidia-vgpud -p ExecMainStatus --value   # 期望：0
systemctl is-active nvidia-vgpu-mgr                     # 期望：active

# vGPU profile
for t in /sys/bus/pci/devices/*/mdev_supported_types/*; do
  printf '%-12s %-24s avail=%s\n' "$(basename $t)" "$(cat $t/name)" "$(cat $t/available_instances)"
done
```

期望看到 20 个 profile（`nvidia-46` ~ `nvidia-241`，1Q~24Q）。

## 把 vGPU 挂给虚拟机

`mdev=` 后面跟的是 **profile 类型名**（不是 UUID），PVE 会自己创建实例：

```bash
qm set 103 -hostpci0 0000:01:00.0,mdev=nvidia-49,pcie=1
qm set 103 -vga virtio        # 保留虚拟显示作为控制台；也可设为 none
qm shutdown 103 && qm start 103
```

常用 profile（6GB 物理显存建议 1Q~4Q）：

| 类型 | 名称 | 显存 |
|---|---|---|
| `nvidia-46` | GRID P40-1Q | 1GB |
| `nvidia-47` | GRID P40-2Q | 2GB |
| `nvidia-49` | GRID P40-4Q | 4GB |
| `nvidia-50` | GRID P40-6Q | 6GB |

挂载后可在 QEMU 侧确认设备真的呈现给客户机：

```bash
echo "info qtree" | qm monitor 103 | grep -A12 vfio
# 期望看到 x-pci-vendor-id = 0x10de、x-pci-device-id = 0x1b38（spoof 的 P40）、class 0x030000
```

## Windows 客户机

### 1. 安装 vGPU Guest Driver

驱动版本必须 **≤ 宿主 vGPU 分支**。宿主是 16.5，因此客户机用 **538.46**：

```
https://storage.googleapis.com/nvidia-drivers-us-public/GRID/vGPU16.5/
  538.46_grid_win10_win11_server2019_server2022_dch_64bit_international.exe
```

把 `.exe` 放进 ISO 挂给 VM（或走共享目录），在 Windows 里安装，安装类型选 **vGPU / GRID**，装完重启。

### 2. 配置授权令牌

```powershell
# 管理员 PowerShell，在仓库 scripts/ 目录下
.\guest-windows.ps1 -TokenPath D:\client_configuration_token.tok
```

脚本会：把令牌复制到 `ClientConfigToken` 目录 → 重启 `NVDisplay.ContainerLocalSystem` → 打印授权状态。

手工做法：

```powershell
Copy-Item D:\client_configuration_token.tok `
  'C:\ProgramData\NVIDIA Corporation\vGPU Licensing\ClientConfigToken\'
Restart-Service NVDisplay.ContainerLocalSystem
& 'nvidia-smi' -q | Select-String 'License'
```

期望：

```
vGPU Software Licensed Product
    License Status                    : Licensed (Expiry: ...)
```

> 没令牌时 vGPU 仍能跑，但 `nvidia-smi` 显示 `Unlicensed`，性能受限。

## License 服务（FastAPI-DLS）

未授权状态下 vGPU 可用但受限。仓库提供社区 license server 的一键部署：

```bash
sudo bash scripts/deploy-dls.sh --port 4444 --url 10.0.5.2 \
     --token-out /var/lib/vz/template/iso/client_configuration_token.tok
```

它会：建 venv → 拉 `fastapi-dls` → 生成自签 CA/服务端证书（10 年）→ 注册 systemd 服务
→ 健康检查 → 生成客户端令牌。

- 默认 lease 90 天，客户机每 24h 续期一次
- **宿主必须常在线**，否则 lease 到期后客户机会掉回 Unlicensed
- 端口可自定义（示例用 4444），令牌里会写入实际地址与端口

> ⚠️ 合规提示：FastAPI-DLS 是社区实现，等价于自建 license server，**绕过 NVIDIA 付费授权**。
> 家用/实验室可接受，商用请购买正式 vGPU 授权。

## 常见问题

**`systemctl status nvidia-vgpud` 显示 `inactive (dead)`**
正常。它是 oneshot 服务，写完 vGPU 配置就退出。判断依据是 `ExecMainStatus` 是否为 0。
只有出现 `status=6/NOTCONFIGURED` + `GPU not supported by vGPU` 才是真故障（解锁库没生效）。

**`nvidia-vgpud` 报 `GPU not supported by vGPU ... DevID: 0x10de / 0x1c07 / 0x10de / 0x0000`**
解锁库没加载。检查：

```bash
ldd /opt/vgpu_unlock-rs/target/release/libvgpu_unlock_rs.so   # 应无 "not a dynamic executable"
systemctl cat nvidia-vgpud | grep LD_PRELOAD
journalctl -u nvidia-vgpud -n 30 --no-pager
```

**千万别用 PVE-Tools 的「部署 vGPU Unlock」**
`/usr/local/bin/pvetools` 会从 PVE-Tools 仓库下载 `libvgpu_unlock_rs_20230207_44d5bb3.so`，
**该文件本身是损坏的**（5.5MB，ELF 头 `Size of this header: 0`，md5
`d91bc39ea6514b9be4d1a76f737344d1`），loader 会拒绝 preload，还会让运行中的
`nvidia-vgpu-mgr` 段错误崩溃。本项目的脚本改为从源码编译，并给产物加 `chattr +i` 防覆盖。

**QEMU 报 `failed to get region 0 info: Invalid argument`**
7.0 的 vfio 核心接管了 region 查询。确认已应用本仓库的移植补丁（新增
`get_region_info_caps` 回调），并重建了 `nvidia-vgpu-vfio.ko`。

**profile 显示 24 个可用实例（1Q=24）但实际开不出来**
因为 spoof 成 GRID P40（24GB），`available_instances` 是按 P40 算的。物理显存只有 6GB，
按真实显存分配（1Q/2Q/4Q）才稳。

**客户机里看不到 NVIDIA 设备**
- 确认 VM 是 OVMF + q35
- `qm config <vmid> | grep hostpci` 确认 `mdev=` 是类型名
- 重启过一次 VM（mdev 实例随 VM 启停重建）

**升级内核后驱动失效**
DKMS 会尝试为新内核重建。若新内核超出补丁适配范围，构建会失败——此时要么回退内核，
要么更新 `patches/` 里的移植补丁。

## 卸载

```bash
sudo bash scripts/deploy-pve.sh --uninstall
```

会移除 DKMS 模块、驱动用户态、解锁库、systemd drop-in 与模块配置。
VM 上的 `hostpci0` 需自行清理。

## 仓库结构

```
README.md
patches/nvidia-535.161.05-linux7.0.patch   # Linux 7.0 内核移植补丁（12 文件）
scripts/deploy-pve.sh                      # 宿主机一键部署
scripts/deploy-dls.sh                      # FastAPI-DLS license server 部署
scripts/guest-windows.ps1                  # Windows 客户机令牌配置
```

## 致谢与许可

- 消费卡解锁补丁：[polloloco/vgpu-proxmox](https://gitlab.com/polloloco/vgpu-proxmox)（AGPL-3.0）
- 设备白名单解锁：[mbilker/vgpu_unlock-rs](https://github.com/mbilker/vgpu_unlock-rs)
- License 服务：[fastapi-dls](https://git.collinwebdesigns.de/oscar.krause/fastapi-dls)
- 本项目脚本与移植补丁：MIT

NVIDIA vGPU 驱动本体版权归 NVIDIA，受其许可协议约束，**不随本仓库分发**。
本项目仅用于个人学习与实验室环境；商用请购买官方 vGPU 授权。
