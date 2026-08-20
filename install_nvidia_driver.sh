#!/bin/bash
set +e

# 自动加执行权限 + sudo 提权
[ -x "$0" ] || chmod +x "$0" 2>/dev/null
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

LOG="/workspace/install_driver_$(date +%Y%m%d_%H%M%S).log"
touch "${LOG}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }
log_info()  { log "[INFO] $*"; }
log_ok()    { log "[OK]   $*"; }
log_warn()  { log "[WARN] $*"; }
log_error() { log "[ERR]  $*"; }

log "============================================"
log " NVIDIA 驱动一键安装脚本"
log " 日志: ${LOG}"
log "============================================"

# 检查是否已安装
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_ok "NVIDIA 驱动已安装且正常工作"
    nvidia-smi 2>/dev/null | head -10 | tee -a "${LOG}"
    log "无需重复安装，退出"
    exit 0
fi

CODENAME="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'noble')"
log_info "Ubuntu 版本代号: ${CODENAME}"

log_info "[1/9] 清理 APT/dpkg 锁..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/debconf/config.dat.lock 2>/dev/null
dpkg --configure -a 2>/dev/null || true

log_info "[2/9] 清理旧 NVIDIA/CUDA 源..."
rm -f /etc/apt/sources.list.d/*nvidia* /etc/apt/sources.list.d/*cuda* /etc/apt/sources.list.d/*dcgm* 2>/dev/null
sed -i '/download\.nvidia\.com\|nobleoper/d' /etc/apt/sources.list 2>/dev/null

log_info "[3/9] 重建 sources.list..."
cat > /etc/apt/sources.list << EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF
if ! (echo > /dev/tcp/mirrors.tuna.tsinghua.edu.cn/443) 2>/dev/null; then
    cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF
fi

log_info "[4/9] apt update..."
rm -rf /var/lib/apt/lists/* 2>/dev/null
mkdir -p /var/lib/apt/lists/partial 2>/dev/null
apt-get update -q -o Acquire::Retries=3 2>&1 | tee -a "${LOG}" || {
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y --fix-broken 2>/dev/null || true
    apt-get update -q 2>&1 | tee -a "${LOG}" || log_warn "apt update 仍失败"
}

log_info "[5/9] 扫描所有内核..."
ALL_KVERS="$(ls -d /lib/modules/*/ 2>/dev/null | sed 's|/lib/modules/||;s|/$||' | sort -V)"
[ -z "${ALL_KVERS}" ] && ALL_KVERS="$(uname -r)"
echo "${ALL_KVERS}" | while read k; do log_info "  内核: ${k}"; done

log_info "[6/9] 安装内核头文件 + dkms + 编译工具..."
for KV in ${ALL_KVERS}; do
    apt-get install -y --no-install-recommends "linux-headers-${KV}" 2>/dev/null || true
done
apt-get install -y --no-install-recommends dkms build-essential pciutils ca-certificates 2>&1 | tee -a "${LOG}" || true

log_info "[7/9] 安装 NVIDIA 驱动..."
DRV_INSTALLED=""
for DRV in nvidia-driver-595 nvidia-driver-580 nvidia-driver-570 nvidia-driver-560 nvidia-driver-550; do
    log_info "  尝试 ${DRV}..."
    apt-get install -y --no-install-recommends "${DRV}" 2>&1 | tee -a "${LOG}" && {
        DRV_INSTALLED="${DRV}"
        log_ok "  ${DRV} 安装成功"
        break
    }
    apt-get install -f -y --fix-broken 2>/dev/null || true
done
if [ -z "${DRV_INSTALLED}" ]; then
    log_warn "  APT 驱动安装失败，尝试 ubuntu-drivers autoinstall..."
    ubuntu-drivers autoinstall 2>&1 | tee -a "${LOG}" || true
    DRV_INSTALLED="$(ubuntu-drivers devices 2>/dev/null | grep -i recommended | awk '{print $3}' | head -n1 || echo 'unknown')"
fi
log_ok "  驱动: ${DRV_INSTALLED}"

# 为所有内核编译模块
log_info "  为所有内核编译 NVIDIA 模块..."
for KV in ${ALL_KVERS}; do
    dkms autoinstall -k "${KV}" 2>&1 | tee -a "${LOG}" || true
done
depmod -a 2>/dev/null || true

log_info "[8/9] 禁用 nouveau + 持久化配置..."
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
cat > /etc/modprobe.d/nvidia.conf << 'EOF'
options nvidia NVreg_EnableGpuFirmware=0
EOF

log_info "[9/9] 重建 initrd + 更新 GRUB..."
for KV in ${ALL_KVERS}; do
    if [ -f "/boot/initrd.img-${KV}" ]; then
        update-initramfs -u -k "${KV}" 2>/dev/null || true
    else
        update-initramfs -c -k "${KV}" 2>/dev/null || true
    fi
done
update-grub 2>&1 | tee -a "${LOG}" || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

# 尝试加载模块
modprobe nvidia 2>/dev/null || true
modprobe nvidia_modeset nvidia_uvm nvidia_drm 2>/dev/null || true

log ""
log "============================================"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_ok "驱动安装成功！"
    nvidia-smi 2>/dev/null | head -10 | tee -a "${LOG}"
    log ""
    log "现在可以运行测试脚本: ./gpu_test.sh"
else
    log_warn "驱动已安装，但需要重启才能生效"
    log_warn "请执行: sudo reboot"
    log_warn "重启后再运行测试脚本: ./gpu_test.sh"
fi
log "============================================"