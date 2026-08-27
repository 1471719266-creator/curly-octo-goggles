#!/bin/bash
set +e

# 自动加权限 + sudo
[ -x "$0" ] || chmod +x "$0" 2>/dev/null
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

LOG="/workspace/nvidia_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p /workspace
touch "${LOG}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }

log "============================================"
log " NVIDIA 驱动安全安装（不破坏 initramfs）"
log " 当前内核: $(uname -r)"
log "============================================"

# 已装好就退出
if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log "驱动已装好！"
    nvidia-smi | head -10
    exit 0
fi

# 第1步：修复损坏的包
log "[1/6] 修复损坏的包..."
dpkg --configure -a 2>/dev/null || true
apt-get --fix-broken install -y 2>/dev/null || true

# 第2步：apt update（不改源！）
log "[2/6] apt update..."
apt-get update -q 2>&1 | tail -3 | tee -a "${LOG}" || true

# 第3步：装基础工具
log "[3/6] 装基础工具..."
apt-get install -y dkms build-essential 2>&1 | tail -5 | tee -a "${LOG}" || true

# 只装当前内核的头文件，不碰其他内核
log "[4/6] 装当前内核头文件..."
apt-get install -y "linux-headers-$(uname -r)" 2>&1 | tail -3 | tee -a "${LOG}" || true
log "  内核: $(uname -r)"

# 第5步：用 ubuntu-drivers 安装（官方工具）
log "[5/6] 安装 NVIDIA 驱动..."

# 方法A：ubuntu-drivers（最可靠）
log "  尝试 ubuntu-drivers install..."
ubuntu-drivers install 2>&1 | tee -a "${LOG}"

if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log "  ubuntu-drivers 成功！"
else
    # 方法B：直接 apt 装
    log "  ubuntu-drivers 没成功，尝试 apt..."
    for DRV in nvidia-driver-570 nvidia-driver-560 nvidia-driver-550 nvidia-driver-535; do
        log "    试 ${DRV}..."
        apt-get install -y "${DRV}" 2>&1 | tail -5 | tee -a "${LOG}"
        apt-get --fix-broken install -y 2>/dev/null || true
        if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
            log "    ${DRV} 成功！"
            break
        fi
    done
fi

# 第6步：验证
log "[6/6] 验证..."
log ""
if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log "============================================"
    log " 成功！驱动已安装"
    log "============================================"
    nvidia-smi | tee -a "${LOG}"
    log ""
    log "现在可以跑: ./gpu_test.sh"
else
    # 尝试 modprobe
    log "  尝试加载模块..."
    modprobe nvidia 2>/dev/null || true
    sleep 2
    if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
        log "  模块加载成功！"
        nvidia-smi | tee -a "${LOG}"
    else
        log "============================================"
        log " 驱动已装但需要重启"
        log " 请执行: sudo reboot"
        log " 重启后: nvidia-smi"
        log "============================================"
    fi
fi