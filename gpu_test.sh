#!/bin/bash
set +e

OUTDIR="/workspace/gpu_test_$(date +%Y%m%d_%H%M%S)"
LOG="${OUTDIR}/test.log"
mkdir -p "${OUTDIR}"
touch "${LOG}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }
log_info()  { log "[INFO] $*"; }
log_ok()    { log "[OK]   $*"; }
log_warn()  { log "[WARN] $*"; }
log_error() { log "[ERR]  $*"; }

log "============================================"
log " NVIDIA GPU 全自动测试脚本"
log " 日志: ${LOG}"
log "============================================"

if [ "$(id -u)" -ne 0 ]; then
    log "需要 root 权限，正在 sudo..."
    exec sudo bash "$0" "$@"
fi

driver_already_ok=false
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_ok "检测到已有可用的 NVIDIA 驱动，跳过安装"
    driver_already_ok=true
else
    log_info "未检测到 NVIDIA 驱动，开始自动安装..."
fi

if [ "${driver_already_ok}" != "true" ]; then

    CODENAME="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'noble')"
    log_info "Ubuntu 版本代号: ${CODENAME}"

    log_info "[安装 1/12] 清理 APT/dpkg 锁..."
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/debconf/config.dat.lock 2>/dev/null
    dpkg --configure -a 2>/dev/null || true

    log_info "[安装 2/12] 清理旧 NVIDIA/CUDA 源..."
    rm -f /etc/apt/sources.list.d/*nvidia* /etc/apt/sources.list.d/*cuda* /etc/apt/sources.list.d/*dcgm* /etc/apt/sources.list.d/*launchpadcontent* 2>/dev/null
    sed -i '/download\.nvidia\.com\|nobleoper\|launchpadcontent/d' /etc/apt/sources.list 2>/dev/null

    log_info "[安装 3/12] 重建 sources.list..."
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

    log_info "[安装 4/12] apt update..."
    rm -rf /var/lib/apt/lists/* 2>/dev/null
    mkdir -p /var/lib/apt/lists/partial 2>/dev/null
    apt-get update -q -o Acquire::Retries=3 2>&1 | tee -a "${LOG}" || {
        dpkg --configure -a 2>/dev/null || true
        apt-get install -f -y --fix-broken 2>/dev/null || true
        apt-get update -q 2>&1 | tee -a "${LOG}" || log_warn "apt update 仍失败"
    }

    log_info "[安装 5/12] 扫描所有内核..."
    ALL_KVERS="$(ls -d /lib/modules/*/ 2>/dev/null | sed 's|/lib/modules/||;s|/$||' | sort -V)"
    [ -z "${ALL_KVERS}" ] && ALL_KVERS="$(uname -r)"
    echo "${ALL_KVERS}" | while read k; do log_info "  内核: ${k}"; done

    log_info "[安装 6/12] 安装所有内核头文件 + dkms + build-essential..."
    for KV in ${ALL_KVERS}; do
        apt-get install -y --no-install-recommends "linux-headers-${KV}" 2>/dev/null || true
    done
    apt-get install -y --no-install-recommends dkms build-essential pciutils ca-certificates 2>&1 | tee -a "${LOG}" || true

    log_info "[安装 7/12] 安装 NVIDIA 驱动..."
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
        add-apt-repository -y ppa:graphics-drivers/ppa 2>/dev/null || true
        apt-get update -q 2>/dev/null || true
        ubuntu-drivers autoinstall 2>&1 | tee -a "${LOG}" || true
        DRV_INSTALLED="$(ubuntu-drivers devices 2>/dev/null | grep -i recommended | awk '{print $3}' | head -n1 || echo 'unknown')"
    fi
    log_ok "  驱动: ${DRV_INSTALLED}"

    log_info "[安装 8/12] 为所有内核编译 NVIDIA 模块..."
    for KV in ${ALL_KVERS}; do
        dkms autoinstall -k "${KV}" 2>&1 | tee -a "${LOG}" || true
    done
    depmod -a 2>/dev/null || true

    log_info "[安装 9/12] 加载 NVIDIA 模块..."
    modprobe nvidia 2>&1 | tee -a "${LOG}" || true
    modprobe nvidia_modeset nvidia_uvm nvidia_drm 2>/dev/null || true
    sleep 2
    if ! lsmod 2>/dev/null | grep -q '^nvidia'; then
        dkms autoinstall -k "$(uname -r)" 2>&1 | tee -a "${LOG}" || true
        modprobe nvidia 2>/dev/null || true
        sleep 2
    fi

    log_info "[安装 10/12] 写入持久化配置..."
    mkdir -p /etc/modprobe.d
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    cat > /etc/modprobe.d/nvidia.conf << 'EOF'
options nvidia NVreg_EnableGpuFirmware=0
EOF

    log_info "[安装 11/12] 重建 initrd + 更新 GRUB..."
    for KV in ${ALL_KVERS}; do
        if [ -f "/boot/initrd.img-${KV}" ]; then
            update-initramfs -u -k "${KV}" 2>/dev/null || true
        else
            update-initramfs -c -k "${KV}" 2>/dev/null || true
        fi
    done
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub 2>/dev/null || true
    update-grub 2>&1 | tee -a "${LOG}" || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

    log_info "[安装 12/12] 验证驱动..."
    NVIDIA_OK=false
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
        NVIDIA_OK=true
        log_ok "  ✅ nvidia-smi 正常，检测到 GPU"
    else
        NS="$(find /usr/lib /usr/bin /usr/local -name 'nvidia-smi' -type f 2>/dev/null | head -1)"
        [ -n "${NS}" ] && ln -sf "${NS}" /usr/local/bin/nvidia-smi 2>/dev/null || true
        nvidia-smi -L 2>/dev/null | grep -q 'GPU' && NVIDIA_OK=true || true
    fi

    if [ "${NVIDIA_OK}" != "true" ]; then
        log ""
        log_warn "============================================"
        log_warn " 驱动安装完成但 GPU 未立即检测到"
        log_warn " 需要 reboot 重启后再运行本脚本"
        log_warn "   sudo reboot"
        log_warn "   重启后: bash /workspace/gpu_test.sh"
        log_warn "============================================"
        exit 0
    fi

    log_ok "✅ NVIDIA 驱动安装完成！开始测试..."
fi

log ""
log "============================================"
log " 开始 GPU 测试"
log "============================================"

gpu_count="$(nvidia-smi -L 2>/dev/null | wc -l || echo 0)"
log_info "检测到 ${gpu_count} 张 GPU"
if [ "${gpu_count}" -eq 0 ]; then
    log_error "没有检测到 NVIDIA GPU！"
    exit 1
fi

log_info "===== GPU 基本信息 ====="
nvidia-smi 2>&1 | tee -a "${LOG}"

log_info "===== GPU 详细信息 ====="
for i in $(seq 0 $((gpu_count - 1))); do
    log_info "GPU ${i}:"
    nvidia-smi -i ${i} --query-gpu=index,name,driver_version,memory.total,memory.free,temperature.gpu,power.draw,power.limit,clocks.current.sm,clocks.current.mem,pstate,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv 2>&1 | tee -a "${LOG}"
done

log_info "===== PCIe 信息 ====="
lspci -nnvv 2>&1 | grep -A 20 'NVIDIA' | tee -a "${LOG}"

log_info "===== PCIe 链路测试 ====="
for i in $(seq 0 $((gpu_count - 1))); do
    log_info "GPU ${i} PCIe 测试:"
    nvidia-smi -i ${i} -q 2>&1 | grep -iE 'pcie|link' | tee -a "${LOG}"
done

log_info "===== 温度监控 30 秒 ====="
for sec in $(seq 1 30); do
    temps="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null)"
    log_info "  ${sec}s: ${temps}"
    sleep 1
done

log_info "===== CUDA 基础测试 ====="
if command -v nvcc >/dev/null 2>&1; then
    nvcc --version 2>&1 | tee -a "${LOG}"
fi
CUDA_BIN="/usr/local/cuda/bin"
if [ -d "${CUDA_BIN}" ]; then
    [ -f "${CUDA_BIN}/deviceQuery" ] && log_info "deviceQuery:" && "${CUDA_BIN}/deviceQuery" 2>&1 | tee -a "${LOG}"
    [ -f "${CUDA_BIN}/bandwidthTest" ] && log_info "bandwidthTest:" && "${CUDA_BIN}/bandwidthTest" 2>&1 | tee -a "${LOG}"
fi

log_info "===== GPU 压力测试 (60秒) ====="
for i in $(seq 0 $((gpu_count - 1))); do
    log_info "GPU ${i} 满载测试 60 秒..."
    sleep 5
    START_TS="$(date +%s)"
    while [ $(( $(date +%s) - START_TS )) -lt 60 ]; do
        TEMP="$(nvidia-smi -i ${i} --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null)"
        POWER="$(nvidia-smi -i ${i} --query-gpu=power.draw --format=csv,noheader 2>/dev/null)"
        log_info "  GPU${i} 温度:${TEMP}°C  功耗:${POWER}W"
        sleep 5
    done
    log_info "  GPU ${i} 压力测试完成"
done

log_info "===== 生成报告 ====="
REPORT="${OUTDIR}/report.txt"
{
    echo "============================================"
    echo " NVIDIA GPU 测试报告"
    echo " 日期: $(date)"
    echo " 内核: $(uname -r)"
    echo "============================================"
    echo ""
    echo "1. 基本信息"
    echo "----------------------------------------"
    nvidia-smi 2>&1
    echo ""
    echo "2. PCIe 链路状态"
    echo "----------------------------------------"
    for i in $(seq 0 $((gpu_count - 1))); do
        echo "GPU ${i}:"
        nvidia-smi -i ${i} --query-gpu=index,name,pcie.link.gen.current,pcie.link.width.current,pcie.link.replay.errors,pcie.link.rx.errors,pcie.link.tx.errors --format=csv 2>&1
        echo ""
    done
    echo "3. 温度记录"
    echo "----------------------------------------"
    echo "见 test.log 中的温度监控数据"
    echo ""
    echo "4. 压力测试结果"
    echo "----------------------------------------"
    echo "见 test.log 中的压力测试数据"
    echo ""
    echo "5. 结论"
    echo "----------------------------------------"
    echo "  共检测到 ${gpu_count} 张 GPU"
    echo "  详细日志: ${LOG}"
} > "${REPORT}"

log ""
log "============================================"
log_ok "测试完成！"
log_ok "报告: ${REPORT}"
log_ok "日志: ${LOG}"
log "============================================"

cat "${REPORT}"