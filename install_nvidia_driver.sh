#!/bin/bash
set +e

[ -x "$0" ] || chmod +x "$0" 2>/dev/null
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

LOG="/workspace/install_driver_$(date +%Y%m%d_%H%M%S).log"
touch "${LOG}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }

log "============================================"
log " NVIDIA 驱动安装（不改系统源版）"
log "============================================"

# 检查是否已装好
if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log "驱动已装好！"
    nvidia-smi | head -10
    exit 0
fi

# 修复损坏的包
log "[1] 修复损坏的包..."
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y 2>&1 | tee -a "${LOG}"
apt-get --fix-broken install -y 2>/dev/null || true

# 先装 dkms 和编译工具（用现有源，不改源）
log "[2] 装 dkms 和编译工具..."
apt-get install -y dkms build-essential 2>&1 | tee -a "${LOG}"

if ! command -v dkms >/dev/null 2>&1; then
    log "dkms 装不上，尝试 apt update 后再装..."
    apt-get update 2>&1 | tail -5 | tee -a "${LOG}"
    apt-get install -y dkms build-essential 2>&1 | tee -a "${LOG}"
fi

# 装内核头文件
log "[3] 装内核头文件..."
apt-get install -y linux-headers-$(uname -r) 2>/dev/null || true
for KV in $(ls /lib/modules/ 2>/dev/null); do
    apt-get install -y "linux-headers-${KV}" 2>/dev/null || true
done

# 用 ubuntu-drivers autoinstall — 最官方的方式
log "[4] ubuntu-drivers autoinstall..."
ubuntu-drivers autoinstall 2>&1 | tee -a "${LOG}"

# 如果还不行，手动装
if ! nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log "ubuntu-drivers 没成功，尝试手动装..."
    for DRV in nvidia-driver-570 nvidia-driver-560 nvidia-driver-550 nvidia-driver-545 nvidia-driver-535; do
        log "  试 ${DRV}..."
        apt-get install -y "${DRV}" 2>&1 | tail -3 | tee -a "${LOG}"
        if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
            log "  ${DRV} 成功！"
            break
        fi
        apt-get install -f -y 2>/dev/null || true
    done
fi

# 验证
log "[5] 验证..."
if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log "============================================"
    log " 成功！"
    log "============================================"
    nvidia-smi | tee -a "${LOG}"
else
    log "============================================"
    log " 需要重启: sudo reboot"
    log " 重启后: nvidia-smi"
    log "============================================"
fi