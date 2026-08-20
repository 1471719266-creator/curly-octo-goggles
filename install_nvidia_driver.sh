#!/bin/bash
set +e

# 自动加执行权限 + sudo 提权
[ -x "$0" ] || chmod +x "$0" 2>/dev/null
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

LOGDIR="/workspace"
mkdir -p "${LOGDIR}"
LOG="${LOGDIR}/install_driver_$(date +%Y%m%d_%H%M%S).log"
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
    log_ok "NVIDIA 驱动已安装且正常"
    nvidia-smi 2>/dev/null | head -10 | tee -a "${LOG}"
    log "无需重复安装"
    exit 0
fi

CODENAME="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'noble')"
log_info "Ubuntu 版本: ${CODENAME}"
log_info "当前内核: $(uname -r)"

# ---- 第1步：清理 ----
log_info "[1/8] 清理 APT 锁..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y 2>/dev/null || true

# ---- 第2步：重建软件源 ----
log_info "[2/8] 配置软件源..."
cat > /etc/apt/sources.list << 'SOURCES'
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
SOURCES

# ---- 第3步：apt update ----
log_info "[3/8] apt update..."
rm -rf /var/lib/apt/lists/* 2>/dev/null
apt-get update -q 2>&1 | tee -a "${LOG}"
if [ $? -ne 0 ]; then
    log_warn "apt update 有报错，继续..."
fi

# ---- 第4步：安装基础依赖 ----
log_info "[4/8] 安装基础依赖 (dkms, build-essential)..."
apt-get install -y dkms build-essential linux-headers-$(uname -r) pciutils 2>&1 | tee -a "${LOG}"
if ! command -v dkms >/dev/null 2>&1; then
    log_error "dkms 安装失败！无法继续"
    log_error "请检查网络连接后重试"
    exit 1
fi
log_ok "dkms 安装成功"

# ---- 第5步：扫描所有内核，安装头文件 ----
log_info "[5/8] 安装所有内核头文件..."
ALL_KVERS="$(ls -d /lib/modules/*/ 2>/dev/null | sed 's|/lib/modules/||;s|/$||' | sort -V)"
[ -z "${ALL_KVERS}" ] && ALL_KVERS="$(uname -r)"
for KV in ${ALL_KVERS}; do
    log_info "  内核: ${KV}"
    apt-get install -y "linux-headers-${KV}" 2>/dev/null || log_warn "  内核 ${KV} 头文件安装跳过"
done

# ---- 第6步：安装 NVIDIA 驱动 ----
log_info "[6/8] 安装 NVIDIA 驱动..."

# 先尝试 ubuntu-drivers autoinstall (最可靠)
log_info "  尝试 ubuntu-drivers autoinstall..."
ubuntu-drivers autoinstall 2>&1 | tee -a "${LOG}"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_ok "ubuntu-drivers 安装成功！"
else
    # 尝试 apt 直接安装
    log_info "  尝试 apt 直接安装..."
    for DRV in nvidia-driver-595 nvidia-driver-580 nvidia-driver-570 nvidia-driver-560 nvidia-driver-550 nvidia-driver-545 nvidia-driver-535; do
        log_info "    尝试 ${DRV}..."
        apt-get install -y --no-install-recommends "${DRV}" 2>&1 | tee -a "${LOG}"
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
            log_ok "    ${DRV} 安装成功！"
            break
        fi
        apt-get install -f -y 2>/dev/null || true
    done
fi

# ---- 第7步：加载驱动 ----
log_info "[7/8] 加载 NVIDIA 模块..."
modprobe nvidia 2>/dev/null || true
modprobe nvidia_modeset 2>/dev/null || true
modprobe nvidia_uvm 2>/dev/null || true
sleep 2

# 如果 lsmod 没有 nvidia，尝试 dkms 编译
if ! lsmod 2>/dev/null | grep -q '^nvidia'; then
    log_info "  尝试 dkms autoinstall..."
    dkms autoinstall 2>&1 | tee -a "${LOG}" || true
    modprobe nvidia 2>/dev/null || true
    sleep 1
fi

# ---- 第8步：验证结果 ----
log_info "[8/8] 验证..."
log ""

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_ok "============================================"
    log_ok " NVIDIA 驱动安装成功！"
    log_ok "============================================"
    nvidia-smi 2>/dev/null | tee -a "${LOG}"
    log ""
    log "现在可以运行: ./gpu_test.sh"
else
    log_warn "============================================"
    log_warn " 驱动安装完成但 GPU 未检测到"
    log_warn " 需要重启生效，请执行:"
    log_warn "   sudo reboot"
    log_warn " 重启后验证:"
    log_warn "   nvidia-smi"
    log_warn " 如果 nvidia-smi 仍不行，手动装:"
    log_warn "   sudo ubuntu-drivers autoinstall"
    log_warn "============================================"
fi