#!/bin/bash
set +e

LOG="/var/log/setup_nvidia_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }

log "============================================"
log " NVIDIA 一键驱动安装脚本"
log " 日志: ${LOG}"
log "============================================"

if [ "$(id -u)" -ne 0 ]; then
    log "需要 root 权限，正在 sudo..."
    exec sudo bash "$0" "$@"
fi

IS_RECOVERY=false
[ -f /proc/cmdline ] && grep -q 'recovery' /proc/cmdline 2>/dev/null && IS_RECOVERY=true

detect_codename() {
    if [ -f /etc/os-release ]; then
        grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"'
    else
        echo "noble"
    fi
}

CODENAME="$(detect_codename)"
log "检测到 Ubuntu 版本代号: ${CODENAME}"

log "[1] 清理 APT/dpkg 锁..."
rm -f /var/lib/apt/lists/lock 2>/dev/null
rm -f /var/cache/apt/archives/lock 2>/dev/null
rm -f /var/lib/dpkg/lock-frontend 2>/dev/null
rm -f /var/lib/dpkg/lock 2>/dev/null
rm -f /var/cache/debconf/config.dat.lock 2>/dev/null
dpkg --configure -a 2>/dev/null || true
log "    OK"

log "[2] 清理旧 NVIDIA/CUDA APT 源..."
rm -f /etc/apt/sources.list.d/*nvidia* 2>/dev/null
rm -f /etc/apt/sources.list.d/*cuda* 2>/dev/null
rm -f /etc/apt/sources.list.d/*dcgm* 2>/dev/null
rm -f /etc/apt/sources.list.d/*launchpadcontent* 2>/dev/null
sed -i '/download\.nvidia\.com\|nobleoper\|launchpadcontent/d' /etc/apt/sources.list 2>/dev/null
log "    OK"

log "[3] 重建 sources.list (${CODENAME})..."
cat > /etc/apt/sources.list << EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF

if ! (echo > /dev/tcp/mirrors.tuna.tsinghua.edu.cn/443) 2>/dev/null; then
    log "    清华源不可达，使用官方源..."
    cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF
fi
log "    OK"

log "[4] apt update..."
rm -rf /var/lib/apt/lists/* 2>/dev/null
mkdir -p /var/lib/apt/lists/partial 2>/dev/null
apt-get update -q -o Acquire::Retries=3 2>&1 | tee -a "${LOG}" || {
    log "    apt update 失败，修复后重试..."
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y --fix-broken 2>/dev/null || true
    apt-get update -q 2>&1 | tee -a "${LOG}" || log "    仍然失败，继续尝试..."
}
log "    OK"

log "[5] 获取所有已安装内核..."
ALL_KVERS=""
if [ -d /lib/modules ]; then
    ALL_KVERS="$(ls -d /lib/modules/*/ 2>/dev/null | sed 's|/lib/modules/||;s|/$||' | sort -V)"
fi
if [ -z "${ALL_KVERS}" ]; then
    ALL_KVERS="$(uname -r)"
fi
log "    内核列表:"
echo "${ALL_KVERS}" | while read k; do log "      ${k}"; done

log "[6] 安装所有内核的头文件 + dkms + build-essential..."
for KV in ${ALL_KVERS}; do
    log "    安装 linux-headers-${KV} ..."
    apt-get install -y --no-install-recommends "linux-headers-${KV}" 2>&1 | tee -a "${LOG}" || true
done
apt-get install -y --no-install-recommends dkms build-essential pciutils ca-certificates 2>&1 | tee -a "${LOG}" || true
log "    OK"

log "[7] 安装 NVIDIA 驱动..."
DRV_INSTALLED=""
for DRV in nvidia-driver-595 nvidia-driver-580 nvidia-driver-570 nvidia-driver-560 nvidia-driver-550; do
    log "    尝试 ${DRV} ..."
    apt-get install -y --no-install-recommends "${DRV}" 2>&1 | tee -a "${LOG}" && {
        DRV_INSTALLED="${DRV}"
        log "    ✅ ${DRV} 安装成功"
        break
    }
    apt-get install -f -y --fix-broken 2>/dev/null || true
done

if [ -z "${DRV_INSTALLED}" ]; then
    log "    所有驱动版本安装失败！"
    log "    尝试 ubuntu-drivers autoinstall..."
    add-apt-repository -y ppa:graphics-drivers/ppa 2>/dev/null || true
    apt-get update -q 2>/dev/null || true
    ubuntu-drivers autoinstall 2>&1 | tee -a "${LOG}" || {
        log "    ❌ ubuntu-drivers 也失败了"
        exit 1
    }
    DRV_INSTALLED="$(ubuntu-drivers devices 2>/dev/null | grep -i recommended | awk '{print $3}' | head -n1 || echo 'unknown')"
fi
log "    驱动: ${DRV_INSTALLED}"

log "[8] 为所有内核编译 NVIDIA 模块 (DKMS)..."
for KV in ${ALL_KVERS}; do
    log "    DKMS 编译 ${KV} ..."
    dkms autoinstall -k "${KV}" 2>&1 | tee -a "${LOG}" || true
done
depmod -a 2>/dev/null || true
log "    OK"

log "[9] 加载当前内核的 NVIDIA 模块..."
modprobe nvidia 2>&1 | tee -a "${LOG}" || true
modprobe nvidia_modeset 2>/dev/null || true
modprobe nvidia_uvm 2>/dev/null || true
modprobe nvidia_drm 2>/dev/null || true
sleep 2

if lsmod 2>/dev/null | grep -q '^nvidia'; then
    log "    ✅ nvidia 模块已加载"
else
    log "    ⚠️  nvidia 模块未加载，尝试 dkms autoinstall 后重试..."
    dkms autoinstall -k "$(uname -r)" 2>&1 | tee -a "${LOG}" || true
    modprobe nvidia 2>&1 | tee -a "${LOG}" || true
    sleep 2
fi

log "[10] 验证 nvidia-smi..."
NVIDIA_OK=false
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi 2>&1 | tee -a "${LOG}"
    if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
        NVIDIA_OK=true
        log "    ✅ nvidia-smi 正常，检测到 GPU"
    else
        log "    ⚠️  nvidia-smi 命令存在但没检测到 GPU"
    fi
else
    log "    ⚠️  nvidia-smi 不在 PATH，查找中..."
    NS="$(find /usr/lib /usr/bin /usr/local -name 'nvidia-smi' -type f 2>/dev/null | head -1)"
    if [ -n "${NS}" ]; then
        ln -sf "${NS}" /usr/local/bin/nvidia-smi 2>/dev/null || true
        nvidia-smi 2>&1 | tee -a "${LOG}" || true
        if nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
            NVIDIA_OK=true
        fi
    fi
fi

log "[11] 重建所有内核的 initrd..."
for KV in ${ALL_KVERS}; do
    log "    重建 initrd-${KV} ..."
    if [ -f "/boot/initrd.img-${KV}" ]; then
        update-initramfs -u -k "${KV}" 2>&1 | tee -a "${LOG}" || true
    else
        update-initramfs -c -k "${KV}" 2>&1 | tee -a "${LOG}" || true
    fi
    ISZ="$(stat -c%s "/boot/initrd.img-${KV}" 2>/dev/null || echo 0)"
    log "      initrd-${KV}: ${ISZ} bytes"
done
log "    OK"

log "[12] 设置 GRUB 默认启动项..."
CURRENT_KVER="$(uname -r)"
LATEST_KVER="$(echo "${ALL_KVERS}" | tail -n1)"

log "    当前内核: ${CURRENT_KVER}"
log "    最新内核: ${LATEST_KVER}"

if command -v grub-set-default >/dev/null 2>&1; then
    MENU_ENTRY="$(grub-reboot 2>/dev/null 2>&1 | head -1 || true)"
    if [ -z "${MENU_ENTRY}" ]; then
        MENU_ENTRY="Ubuntu"
    fi
    if [ "${IS_RECOVERY}" != "true" ]; then
        grub-set-default "${MENU_ENTRY}" 2>&1 | tee -a "${LOG}" || true
        log "    ✅ GRUB 默认启动项已设置为: ${MENU_ENTRY}"
    fi
fi

sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub 2>/dev/null || true
update-grub 2>&1 | tee -a "${LOG}" || grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "${LOG}" || true
log "    ✅ GRUB 已更新"

log "[13] 写入 nvidia 持久化配置..."
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

cat > /etc/modprobe.d/nvidia.conf << 'EOF'
options nvidia NVreg_EnableGpuFirmware=0
options nvidia_drm parameters
EOF

log "    OK"

log ""
log "============================================"
log " 安装完成汇总"
log "============================================"
log " Ubuntu 版本: ${CODENAME}"
log " 已安装内核: $(echo "${ALL_KVERS}" | wc -l) 个"
echo "${ALL_KVERS}" | while read k; do log "    ${k}"; done
log " NVIDIA 驱动: ${DRV_INSTALLED}"
log " nvidia 模块: $(lsmod 2>/dev/null | grep -c '^nvidia') 个"
log " nvidia-smi:   $([ "${NVIDIA_OK}" = "true" ] && echo '✅ 正常' || echo '⚠️  需重启')"
log ""
log " 下一步: reboot 重启系统"
log " 重启后运行: bash /workspace/gpu_test.sh"
log "============================================"

if [ "${NVIDIA_OK}" != "true" ]; then
    log ""
    log " ⚠️  当前 nvidia 模块未完全加载（可能是 nouveau 冲突或内核不匹配）"
    log "    重启后进系统再执行 nvidia-smi 验证"
    log "    如果重启后仍不行，进 GRUB → Advanced → 选带 nvidia 模块的内核"
fi