#!/usr/bin/env bash
#
# Pascal-vgpu-linux — 在 Proxmox VE 9（Linux 7.0 内核）上一键部署 NVIDIA vGPU 宿主驱动
#
#   - 适用于 Pascal 架构消费卡（P106-100 / P104-100 / GTX 10xx 等）
#   - 驱动：NVIDIA vGPU 16.5 宿主驱动 535.161.05（vGPU 17.0 起官方移除 Pascal 支持）
#   - 补丁：polloloco/vgpu-proxmox 的消费卡解锁补丁 + 本项目针对 7.0 内核的移植补丁
#   - 解锁：vgpu_unlock-rs（自编译，不用 PVE-Tools 那个损坏的预编译库）
#
# 用法：
#   sudo bash deploy-pve.sh                 # 交互式一键部署
#   sudo bash deploy-pve.sh --yes           # 全自动
#   sudo bash deploy-pve.sh --dry-run       # 只检查环境并打印计划
#   sudo bash deploy-pve.sh --driver /path/NVIDIA-Linux-x86_64-535.161.05-vgpu-kvm.run
#   sudo bash deploy-pve.sh --with-license 4444
#   sudo bash deploy-pve.sh --uninstall
#
# 仓库：https://github.com/Canary233/Pascal-vgpu-linux
# 许可：MIT（脚本与补丁）。NVIDIA 驱动本体不随仓库分发，由脚本按需下载。
#
set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly DRIVER_VERSION="535.161.05"
readonly DRIVER_RUN="NVIDIA-Linux-x86_64-${DRIVER_VERSION}-vgpu-kvm.run"
readonly DRIVER_MD5="bad6e09aeb58942750479f091bb9c4b6"
readonly DRIVER_URL="https://mega.nz/file/RvsyyBaB#7fe_caaJkBHYC6rgFKtiZdZKkAvp7GNjCSa8ufzkG20"
readonly POLLOCOLO_PATCH_URL="https://gitlab.com/polloloco/vgpu-proxmox/-/raw/master/535.161.05.patch"
readonly UNLOCK_REPO="https://github.com/mbilker/vgpu_unlock-rs"
readonly WORKDIR="/var/tmp/pascal-vgpu-build"
readonly SRC_DIR="/usr/src/nvidia-${DRIVER_VERSION}"
readonly UNLOCK_DIR="/opt/vgpu_unlock-rs"
readonly UNLOCK_SO="${UNLOCK_DIR}/target/release/libvgpu_unlock_rs.so"

ASSUME_YES=0
DRY_RUN=0
FORCE_USERSPACE=0
DRIVER_RUN_PATH=""
EXTRACT_ROOT=""
CUSTOM_RUN=""
DO_UNINSTALL=0
DRIVER_PATH=""
WITH_LICENSE=""
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_PATCH="${REPO_DIR}/patches/nvidia-${DRIVER_VERSION}-linux7.0.patch"

# ---------------------------------------------------------------- 基础工具

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

run() {
    if (( DRY_RUN )); then
        printf '    [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

confirm() {
    (( ASSUME_YES )) && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------- 参数解析

while (( $# )); do
    case "$1" in
        --yes|-y)         ASSUME_YES=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --driver)         DRIVER_PATH="${2:?--driver 需要路径}"; shift ;;
        --with-license)   WITH_LICENSE="${2:-4444}"; shift ;;
        --force-userspace) FORCE_USERSPACE=1 ;;
        --uninstall)      DO_UNINSTALL=1 ;;
        --help|-h)        usage ;;
        *) die "未知参数：$1（--help 查看用法）" ;;
    esac
    shift
done

# ---------------------------------------------------------------- 环境检查

preflight() {
    (( EUID == 0 )) || die "需要 root 权限运行"

    [[ -f /etc/pve/pve-version ]] || [[ -d /etc/pve ]] \
        || warn "未检测到 /etc/pve，可能不是 Proxmox VE 主机"

    [[ "$(uname -m)" == "x86_64" ]] || die "仅支持 x86_64"

    local kver; kver="$(uname -r)"
    log "内核：${kver}"
    if [[ ! -d "/lib/modules/${kver}/build" ]]; then
        warn "缺少内核头文件目录 /lib/modules/${kver}/build，将在依赖步骤安装"
    fi

    case "${kver}" in
        6.8.*|6.1[0-9].*|7.*) : ;;
        *) warn "本脚本在 6.8 / 6.1x / 7.0 内核上验证过，当前 ${kver} 未验证，继续可能失败" ;;
    esac

    if grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline; then
        ok "IOMMU 已启用"
    else
        warn "内核命令行未见 intel_iommu=on / amd_iommu=on，vGPU 无法工作"
        warn "请编辑 /etc/default/grub 的 GRUB_CMDLINE_LINUX_DEFAULT 后 update-grub 并重启"
    fi

    local gpu
    gpu="$(lspci -nn | grep -Ei '10de:' | head -5 || true)"
    if [[ -z "${gpu}" ]]; then
        die "未检测到 NVIDIA 显卡"
    fi
    log "检测到 NVIDIA 设备："
    printf '      %s\n' "${gpu}"

    if ! grep -qiE 'Pascal|P106|P104|P102|GP10[0-9]|1c0[0-9]|1b8[0-9]' <<<"${gpu}"; then
        warn "未识别出 Pascal 架构设备，本项目的补丁与驱动版本针对 Pascal 设计"
        confirm "仍然继续？" || exit 1
    fi

    [[ -f "${PORT_PATCH}" ]] || die "缺少内核移植补丁：${PORT_PATCH}"
    log "移植补丁：${PORT_PATCH}"
}

# ---------------------------------------------------------------- 依赖

install_deps() {
    log "安装依赖（内核头文件 / dkms / 编译工具 / 解锁库构建链）"
    run apt-get update -qq

    local kver; kver="$(uname -r)"
    local meta="proxmox-headers-$(cut -d. -f1,2 <<<"${kver}")"

    local pkgs=(dkms gcc make libc6-dev curl git patch rsync genisoimage megatools cargo rustc)
    run apt-get install -y -q "${pkgs[@]}" || die "依赖安装失败"

    if ! run apt-get install -y -q "proxmox-headers-${kver}"; then
        warn "proxmox-headers-${kver} 不可用，尝试元包 ${meta}"
        run apt-get install -y -q "${meta}" || die "内核头文件安装失败"
    fi

    if (( ! DRY_RUN )) && [[ ! -d "/lib/modules/${kver}/build" ]]; then
        die "内核头文件仍未就绪：/lib/modules/${kver}/build 不存在"
    fi
    ok "依赖就绪"
}

# ---------------------------------------------------------------- 驱动包

fetch_driver() {
    mkdir -p "${WORKDIR}"
    local target="${WORKDIR}/${DRIVER_RUN}"

    if [[ -n "${DRIVER_PATH}" ]]; then
        [[ -f "${DRIVER_PATH}" ]] || die "找不到驱动文件：${DRIVER_PATH}"
        log "使用本地驱动包：${DRIVER_PATH}"
        run cp -f "${DRIVER_PATH}" "${target}"
    elif [[ -f "${target}" ]]; then
        log "复用已下载的驱动包：${target}"
    else
        log "从社区镜像下载 vGPU ${DRIVER_VERSION} 宿主驱动（约 50MB）"
        run megadl --path "${WORKDIR}" "${DRIVER_URL}" \
            || die "下载失败。请手动下载后使用 --driver <路径> 重跑"
        # megadl 可能把文件写成目录名，归一化
        # megadl 的 --path 在部分版本会直接把目标当成文件名，这里统一命名
        if [[ -f "${WORKDIR}/vgpu_dl" ]]; then mv -f "${WORKDIR}/vgpu_dl" "${target}"; fi
    fi

    (( DRY_RUN )) && { log "[dry-run] 跳过校验"; return 0; }

    [[ -f "${target}" ]] || die "驱动包不存在：${target}"
    local sum; sum="$(md5sum "${target}" | cut -d' ' -f1)"
    if [[ "${sum}" != "${DRIVER_MD5}" ]]; then
        die "MD5 不匹配（期望 ${DRIVER_MD5}，实际 ${sum}）。文件可能损坏，请用 --driver 指定官方包"
    fi
    chmod +x "${target}"
    ok "驱动包校验通过（md5 ${sum}）"
    DRIVER_RUN_PATH="${target}"
}

# ---------------------------------------------------------------- 打补丁

build_patched() {
    local run="${DRIVER_RUN_PATH}"
    local custom="${run%.run}-custom.run"
    local pollo="${WORKDIR}/535.161.05.patch"

    if (( DRY_RUN )); then
        log "[dry-run] 将执行："
        log "  1) curl -o ${pollo} ${POLLOCOLO_PATCH_URL}"
        log "  2) ${DRIVER_RUN} --apply-patch 535.161.05.patch"
        log "  3) 解包 -custom.run 并 patch -p1 < ${PORT_PATCH}"
        DRIVER_RUN_PATH="${DRIVER_RUN_PATH:-${run}}"
        return 0
    fi

    log "下载 polloloco 消费卡解锁补丁"
    run curl -fsSL -o "${pollo}" "${POLLOCOLO_PATCH_URL}" || die "补丁下载失败"

    log "应用解锁补丁（生成 -custom.run）"
    ( cd "${WORKDIR}" && run ./"${DRIVER_RUN}" --apply-patch "${pollo}" >"${WORKDIR}/apply-patch.log" 2>&1 ) \
        || die "apply-patch 失败（见 ${WORKDIR}/apply-patch.log）"

    log "解包并应用 7.0 内核移植补丁"
    # 注意：makeself 的 --target 目录必须不存在，它会自己创建
    rm -rf "${WORKDIR}/extract"
    ( cd "${WORKDIR}" && run ./"$(basename "${custom}")" -x --target "${WORKDIR}/extract" >/dev/null ) \
        || die "解包失败"

    # 解包根目录：优先取直接包含 kernel/conftest.sh 的目录
    local root="${WORKDIR}/extract"
    if [[ ! -f "${root}/kernel/conftest.sh" ]]; then
        root="$(dirname "$(find "${WORKDIR}/extract" -maxdepth 3 -name conftest.sh -path '*/kernel/*' | head -1)")"
        root="$(dirname "${root}")"
    fi
    [[ -f "${root}/kernel/conftest.sh" ]] || die "解包目录异常：未找到 kernel/conftest.sh"

    if ! patch -p1 --forward -d "${root}" < "${PORT_PATCH}" >/dev/null; then
        die "移植补丁应用失败（驱动版本或补丁不匹配？）"
    fi
    ok "补丁应用完成：${root}"
    EXTRACT_ROOT="${root}"
    CUSTOM_RUN="${WORKDIR}/$(basename "${custom}")"
}

# ---------------------------------------------------------------- 用户态安装

install_userspace() {
    log "安装驱动用户态（nvidia-vgpud / nvidia-vgpu-mgr / vgpuConfig.xml）"

    local cur_ver=""
    cur_ver="$(modinfo -F version nvidia 2>/dev/null || true)"

    if (( ! FORCE_USERSPACE )) && (( ! DRY_RUN )) \
       && [[ "${cur_ver}" == "${DRIVER_VERSION}" ]] \
       && [[ -x /usr/bin/nvidia-vgpud ]] \
       && [[ -f /usr/share/nvidia/vgpu/vgpuConfig.xml ]]; then
        ok "已安装同版本用户态（${cur_ver}），跳过重装（需要时加 --force-userspace）"
        return 0
    fi

    # nvidia 模块被占用时，installer 的 pre-unload 钩子会失败（例如有 VM 正在用 vGPU）
    local used
    used="$(lsmod | awk '$1=="nvidia"{print $3}')"
    if [[ -n "${used}" && "${used}" != "0" ]] && (( ! FORCE_USERSPACE )); then
        warn "nvidia 模块正被占用（引用计数 ${used}），跳过用户态安装以免失败"
        warn "需要重装时：先关闭使用 vGPU 的虚拟机，然后"
        warn "  systemctl stop nvidia-vgpu-mgr nvidia-vgpud"
        warn "  modprobe -r nvidia_vgpu_vfio nvidia"
        warn "  重新执行本脚本（可加 --force-userspace）"
        return 0
    fi

    if (( ! DRY_RUN )) && [[ -z "${CUSTOM_RUN}" ]]; then
        die "内部错误：未找到打过补丁的 -custom.run"
    fi
    run "${CUSTOM_RUN:-<patched-run>}" --no-kernel-modules --no-dkms \
        --disable-nouveau --no-nouveau-check --silent \
        || die "用户态安装失败，详见 /var/log/nvidia-installer.log"
    ok "用户态安装完成"
}

# ---------------------------------------------------------------- 内核模块（DKMS）

install_dkms() {
    local kver; kver="$(uname -r)"
    log "注册 DKMS 源并构建内核模块（kernel ${kver}）"

    run rm -rf "${SRC_DIR}"
    run mkdir -p "${SRC_DIR}"
    if (( ! DRY_RUN )); then
        # 注意：不能排除 *.o_binary —— nvidia/nv-kernel.o_binary 是闭源核心 blob，链接必需
        rsync -a \
            --exclude='*.o' --exclude='*.ko' \
            --exclude='*.mod' --exclude='*.mod.c' --exclude='*.cmd' \
            --exclude='conftest/' --exclude='modules.order' \
            --exclude='Module.symvers' --exclude='.tmp_versions' \
            --exclude='nv-kernel.o' --exclude='nv_compiler.h' \
            "${EXTRACT_ROOT}/kernel/" "${SRC_DIR}/"
        cat > "${SRC_DIR}/dkms.conf" <<EOF
PACKAGE_NAME="nvidia"
PACKAGE_VERSION="${DRIVER_VERSION}"
AUTOINSTALL="yes"

MAKE[0]="'make' -j\$(nproc) NV_EXCLUDE_BUILD_MODULES='' KERNEL_UNAME=\${kernelver} modules"

BUILT_MODULE_NAME[0]="nvidia"
BUILT_MODULE_LOCATION[0]="."
DEST_MODULE_LOCATION[0]="/kernel/drivers/video"

BUILT_MODULE_NAME[1]="nvidia-vgpu-vfio"
BUILT_MODULE_LOCATION[1]="."
DEST_MODULE_LOCATION[1]="/kernel/drivers/video"
EOF
    fi

    run dkms remove -m nvidia -v "${DRIVER_VERSION}" --all || true
    run dkms add -m nvidia -v "${DRIVER_VERSION}" || true
    run dkms build -m nvidia -v "${DRIVER_VERSION}" -k "${kver}" --force \
        || die "DKMS 构建失败，查看 /var/lib/dkms/nvidia/${DRIVER_VERSION}/build/make.log"
    run dkms install -m nvidia -v "${DRIVER_VERSION}" -k "${kver}" --force \
        || die "DKMS 安装失败"
    ok "内核模块已安装到 /lib/modules/${kver}/updates/dkms/"
}

# ---------------------------------------------------------------- 解锁库

install_unlock() {
    log "编译并安装 vgpu_unlock-rs（不要使用 PVE-Tools 的预编译库，它是损坏文件）"

    run rm -rf "${WORKDIR}/vgpu_unlock-rs"
    run git clone --depth=1 -q "${UNLOCK_REPO}" "${WORKDIR}/vgpu_unlock-rs" \
        || die "克隆 vgpu_unlock-rs 失败"

    if (( DRY_RUN )); then
        log "[dry-run] cargo build --release"
    else
        ( cd "${WORKDIR}/vgpu_unlock-rs" && cargo build --release >/dev/null 2>&1 ) \
            || die "cargo build 失败"
    fi

    run mkdir -p "$(dirname "${UNLOCK_SO}")"
    run chattr -i "${UNLOCK_SO}" || true
    run cp -f "${WORKDIR}/vgpu_unlock-rs/target/release/libvgpu_unlock_rs.so" "${UNLOCK_SO}"
    run chmod 755 "${UNLOCK_SO}"
    run chattr +i "${UNLOCK_SO}" || warn "chattr +i 失败（文件系统不支持？）"

    local unit
    for unit in nvidia-vgpud nvidia-vgpu-mgr; do
        run mkdir -p "/etc/systemd/system/${unit}.service.d"
        if (( ! DRY_RUN )); then
            cat > "/etc/systemd/system/${unit}.service.d/vgpu_unlock.conf" <<EOF
[Service]
Environment=LD_PRELOAD=${UNLOCK_SO}
EOF
        fi
    done
    ok "解锁库已安装并加写保护"
}

# ---------------------------------------------------------------- 系统配置

configure_system() {
    log "写入系统配置（nouveau 屏蔽 / 模块开机加载 / vfio）"

    if (( ! DRY_RUN )); then
        printf 'blacklist nouveau\noptions nouveau modeset=0\n' \
            > /etc/modprobe.d/blacklist-nvidia-nouveau.conf

        printf '# Pascal vGPU 宿主驱动\nnvidia\nnvidia-vgpu-vfio\n' \
            > /etc/modules-load.d/nvidia-vgpu.conf

        # vfio 三件套（vfio_virqfd 自 6.6 起并入 vfio，不再单独加载）
        touch /etc/modules
        local m
        for m in vfio vfio_iommu_type1 vfio_pci; do
            grep -qx "${m}" /etc/modules || echo "${m}" >> /etc/modules
        done
    fi

    run systemctl daemon-reload
    ok "配置写入完成"
}

# ---------------------------------------------------------------- 启动与验证

start_and_verify() {
    log "加载模块并启动 vGPU 服务"

    if (( DRY_RUN )); then
        log "[dry-run] modprobe nvidia && modprobe nvidia-vgpu-vfio"
        log "[dry-run] systemctl restart nvidia-vgpud nvidia-vgpu-mgr"
        return 0
    fi

    # nouveau 若正占用显卡，先卸载
    if lsmod | grep -q '^nouveau'; then
        warn "nouveau 正在使用显卡，尝试卸载"
        modprobe -r nouveau || warn "nouveau 卸载失败，重启后再试"
    fi

    modprobe nvidia || die "nvidia 模块加载失败：dmesg | tail 查看原因"
    modprobe nvidia-vgpu-vfio || die "nvidia-vgpu-vfio 模块加载失败"

    systemctl enable nvidia-vgpud nvidia-vgpu-mgr >/dev/null 2>&1 || true
    systemctl restart nvidia-vgpud
    sleep 4
    systemctl restart nvidia-vgpu-mgr
    sleep 2

    local rc; rc="$(systemctl show nvidia-vgpud -p ExecMainStatus --value)"
    local types; types="$(ls /sys/bus/pci/devices/*/mdev_supported_types 2>/dev/null | wc -l)"

    echo
    if [[ "${rc}" == "0" ]] && (( types > 0 )); then
        ok "vGPU 就绪：nvidia-vgpud 退出码 ${rc}，生成 ${types} 个 mdev 类型"
        echo
        log "可用 profile："
        local t
        for t in $(ls /sys/bus/pci/devices/*/mdev_supported_types 2>/dev/null); do
            printf '      %-12s %-24s avail=%s\n' \
                "$(basename "$t")" "$(cat "$t/name" 2>/dev/null)" "$(cat "$t/available_instances" 2>/dev/null)"
        done | head -25
        echo
        log "注意：nvidia-vgpud 是 oneshot 服务，写完配置就退出，"
        log "      systemctl status 显示 inactive (dead) 属正常，只看 ExecMainStatus 是否为 0。"
    else
        warn "vGPU 未就绪（vgpud 退出码 ${rc}，mdev 类型 ${types}）"
        warn "排查："
        warn "  journalctl -u nvidia-vgpud -n 50 --no-pager"
        warn "  journalctl -u nvidia-vgpu-mgr -n 50 --no-pager"
        warn "  dmesg | tail -50"
        warn "常见原因：解锁库未生效 / IOMMU 未开启 / 内核与驱动不匹配"
        return 1
    fi
}

# ---------------------------------------------------------------- License

deploy_license() {
    local port="${1:-4444}"
    log "部署 FastAPI-DLS（端口 ${port}）"
    local dls_script="${REPO_DIR}/scripts/deploy-dls.sh"
    [[ -f "${dls_script}" ]] || { warn "缺少 ${dls_script}，跳过 license 部署"; return 0; }
    run bash "${dls_script}" --port "${port}" --yes
}

# ---------------------------------------------------------------- 卸载

do_uninstall() {
    warn "开始卸载 Pascal vGPU 宿主驱动"
    confirm "确认卸载？" || exit 1

    systemctl stop nvidia-vgpu-mgr nvidia-vgpud 2>/dev/null || true
    systemctl disable nvidia-vgpu-mgr nvidia-vgpud 2>/dev/null || true

    dkms remove -m nvidia -v "${DRIVER_VERSION}" --all 2>/dev/null || true
    rm -rf "${SRC_DIR}"

    if [[ -x /usr/bin/nvidia-uninstall ]]; then
        /usr/bin/nvidia-uninstall --silent 2>/dev/null || true
    fi

    rm -f /etc/modules-load.d/nvidia-vgpu.conf
    rm -f /etc/modprobe.d/blacklist-nvidia-nouveau.conf
    rm -rf /etc/systemd/system/nvidia-vgpud.service.d /etc/systemd/system/nvidia-vgpu-mgr.service.d
    chattr -i "${UNLOCK_SO}" 2>/dev/null || true
    rm -rf "${UNLOCK_DIR}"
    systemctl daemon-reload

    ok "卸载完成。恢复 nouveau 需重启；vGPU 相关配置（mdev 挂载）请自行清理 VM 配置"
}

# ---------------------------------------------------------------- 主流程

main() {
    echo
    echo "  Pascal vGPU on Proxmox VE ${SCRIPT_VERSION}"
    echo "  驱动 ${DRIVER_VERSION} + polloloco 解锁 + Linux 7.0 移植"
    echo

    if (( DO_UNINSTALL )); then
        preflight
        do_uninstall
        exit 0
    fi

    preflight
    (( DRY_RUN )) || confirm "即将安装 vGPU 宿主驱动，会屏蔽 nouveau 并重建内核模块，继续？" || exit 1

    install_deps
    fetch_driver
    build_patched
    install_userspace
    install_dkms
    install_unlock
    configure_system
    start_and_verify || exit 1

    if [[ -n "${WITH_LICENSE}" ]]; then
        deploy_license "${WITH_LICENSE}"
    fi

    echo
    ok "全部完成"
    cat <<'EOF'

下一步：
  1) 创建 vGPU 实例并挂给虚拟机（示例 4Q/4GB）：
       qm set <VMID> -hostpci0 0000:01:00.0,mdev=nvidia-49,pcie=1

  2) Windows 客户机：
       - 安装 NVIDIA vGPU Guest Driver 538.46（16.5 配套版本）
       - 把 client_configuration_token.tok 放到
         C:\ProgramData\NVIDIA Corporation\vGPU Licensing\ClientConfigToken\
       - Restart-Service NVDisplay.ContainerLocalSystem

  详见 README.md
EOF
}

main "$@"
