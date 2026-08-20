#!/bin/bash
set +e

# 自动加执行权限 + sudo 提权
[ -x "$0" ] || chmod +x "$0" 2>/dev/null
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# ========== 输出目录 ==========
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
log " NVIDIA GPU 全自动测试脚本（完整版）"
log " 功能: 驱动安装 + gpu_burn + fieldiag"
log "       温度报警 + 超时暂停 + 自动报告"
log " 日志: ${LOG}"
log "============================================"

# ========== 用户交互：测试参数设置 ==========
log_info "请设置测试参数（直接输入数字回车确认）:"

# GPU burn 测试时间（秒）
read -p "GPU burn 压力测试时间（秒，默认300）: " BURN_TIME
BURN_TIME="${BURN_TIME:-300}"

# 温度报警阈值
read -p "温度报警阈值（°C，默认85）: " TEMP_ALARM
TEMP_ALARM="${TEMP_ALARM:-85}"

# 温度超限自动暂停阈值
read -p "温度超限自动暂停阈值（°C，默认90）: " TEMP_PAUSE
TEMP_PAUSE="${TEMP_PAUSE:-90}"

# fieldiag 测试等级（1=快速 2=标准 3=完整）
read -p "fieldiag 测试等级（1=快速/2=标准/3=完整，默认2）: " FIELD_LEVEL
FIELD_LEVEL="${FIELD_LEVEL:-2}"

log_info "测试参数:"
log_info "  GPU burn 时间: ${BURN_TIME} 秒"
log_info "  温度报警: ${TEMP_ALARM}°C"
log_info "  温度暂停: ${TEMP_PAUSE}°C"
log_info "  fieldiag 等级: ${FIELD_LEVEL}"
log ""

# ========== 安装目录定义 ==========
INSTALL_DIR="/opt/gpu_test_tools"
FIELDIAG_DIR="${INSTALL_DIR}/fieldiag"
GPUBURN_DIR="${INSTALL_DIR}/gpu_burn"
CUDA_DIR="/usr/local/cuda"
mkdir -p "${INSTALL_DIR}"

# ========== 第一步：NVIDIA 驱动安装 ==========
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
    rm -f /etc/apt/sources.list.d/*nvidia* /etc/apt/sources.list.d/*cuda* /etc/apt/sources.list.d/*dcgm* 2>/dev/null
    sed -i '/download\.nvidia\.com\|nobleoper/d' /etc/apt/sources.list 2>/dev/null

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

    log_info "[安装 6/12] 安装内核头文件 + dkms + 编译工具..."
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

    log_info "[安装 10/12] 禁用 nouveau + 持久化配置..."
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
    update-grub 2>&1 | tee -a "${LOG}" || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

    log_info "[安装 12/12] 验证驱动..."
    NVIDIA_OK=false
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
        NVIDIA_OK=true
        log_ok "  nvidia-smi 正常，检测到 GPU"
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
        log_warn "   重启后: ./$0"
        log_warn "============================================"
        exit 0
    fi
    log_ok "NVIDIA 驱动安装完成！"
fi

# ========== 第二步：安装 CUDA Toolkit ==========
log_info "检查 CUDA Toolkit..."
if [ -d "${CUDA_DIR}" ] && [ -f "${CUDA_DIR}/bin/nvcc" ]; then
    log_ok "CUDA Toolkit 已安装"
else
    log_info "安装 CUDA Toolkit..."
    apt-get install -y nvidia-cuda-toolkit 2>&1 | tee -a "${LOG}" || log_warn "CUDA Toolkit 安装失败"
fi

# ========== 第三步：安装 gpu_burn ==========
log_info "检查 gpu_burn..."
if [ -f "${GPUBURN_DIR}/gpu_burn" ]; then
    log_ok "gpu_burn 已安装: ${GPUBURN_DIR}/gpu_burn"
else
    log_info "安装 gpu_burn..."
    mkdir -p "${GPUBURN_DIR}"
    apt-get install -y git 2>/dev/null || true
    # 尝试从 GitHub 下载
    if git clone https://github.com/wilicc/gpu-burn.git "${GPUBURN_DIR}/src" 2>/dev/null; then
        cd "${GPUBURN_DIR}/src"
        make 2>&1 | tee -a "${LOG}"
        cp -f gpu_burn "${GPUBURN_DIR}/" 2>/dev/null || true
        cp -f compare "${GPUBURN_DIR}/" 2>/dev/null || true
        cd /
        log_ok "gpu_burn 安装完成"
    else
        log_warn "无法从 GitHub 下载 gpu_burn，尝试 apt 安装..."
        apt-get install -y gpu-burn 2>/dev/null || log_warn "gpu_burn apt 安装也失败，跳过 gpu_burn 测试"
    fi
fi

# ========== 第四步：检查 fieldiag ==========
log_info "检查 fieldiag 原厂诊断工具..."
FIELDIAG_AVAILABLE=false
FIELDIAG_BIN="${FIELDIAG_DIR}/fieldiag"
if [ -f "${FIELDIAG_BIN}" ]; then
    FIELDIAG_AVAILABLE=true
    log_ok "fieldiag 已安装: ${FIELDIAG_BIN}"
else
    log_warn "fieldiag 未找到"
    log_info "  fieldiag 是 NVIDIA 原厂诊断工具，需要从 NVIDIA 官网下载"
    log_info "  如果已有 fieldiag 文件，请放到: ${FIELDIAG_DIR}/"
    log_info "  PCIe 插槽 GPU 不需要 fieldiag，会自动跳过"
fi

# ========== 第五步：GPU 检测和分类 ==========
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

# 判断 GPU 类型：数据中心 GPU (H100/H200/B100/B200/B300等) vs 消费级/工作站 GPU
DATACENTER_GPUS=""
PCIE_GPUS=""
gpu_index=0

while IFS= read -r line; do
    gpu_name="$(echo "${line}" | sed 's/GPU .*: //;s/ (UUID.*//')"
    log_info "GPU ${gpu_index}: ${gpu_name}"
    
    # 判断是否为数据中心 GPU
    if echo "${gpu_name}" | grep -qiE 'H100|H200|A100|A800|H800|B100|B200|B300|L40S?|L40|V100'; then
        DATACENTER_GPUS="${DATACENTER_GPUS} ${gpu_index}"
        log_info "  -> 数据中心 GPU，适用 fieldiag"
    else
        PCIE_GPUS="${PCIE_GPUS} ${gpu_index}"
        log_info "  -> PCIe 工作站 GPU，跳过 fieldiag"
    fi
    gpu_index=$((gpu_index + 1))
done < <(nvidia-smi -L 2>/dev/null)

log_info "数据中心 GPU: ${DATACENTER_GPUS:-无}"
log_info "PCIe GPU: ${PCIE_GPUS:-无}"
log ""

# ========== 测试 1: GPU 基本信息 ==========
log_info "===== 测试 1: GPU 基本信息 ====="
nvidia-smi 2>&1 | tee -a "${LOG}"
log ""
for i in $(seq 0 $((gpu_count - 1))); do
    log_info "GPU ${i} 详细信息:"
    nvidia-smi -i ${i} --query-gpu=index,name,driver_version,memory.total,memory.free,temperature.gpu,power.draw,power.limit,clocks.current.sm,clocks.current.mem,pstate,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv 2>&1 | tee -a "${LOG}"
done
log ""

# ========== 测试 2: PCIe 链路测试 ==========
log_info "===== 测试 2: PCIe 链路测试 ====="
lspci -nnvv 2>&1 | grep -A 20 'NVIDIA' | tee -a "${LOG}"
log ""
for i in $(seq 0 $((gpu_count - 1))); do
    log_info "GPU ${i} PCIe 链路:"
    nvidia-smi -i ${i} -q 2>&1 | grep -iE 'pcie|link' | tee -a "${LOG}"
done
log ""

# ========== 测试 3: 温度监控（带报警） ==========
log_info "===== 测试 3: 温度监控 30 秒（报警:${TEMP_ALARM}°C 暂停:${TEMP_PAUSE}°C）====="
TEMP_MONITOR_PAUSED=false
for sec in $(seq 1 30); do
    temps=""
    for i in $(seq 0 $((gpu_count - 1))); do
        temp="$(nvidia-smi -i ${i} --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | tr -d ' ')"
        temps="${temps} GPU${i}=${temp}°C"
        # 温度报警
        if [ -n "${temp}" ] && [ "${temp}" -ge "${TEMP_ALARM}" ] 2>/dev/null; then
            log_warn "  [温度报警] GPU${i} 温度 ${temp}°C 超过报警阈值 ${TEMP_ALARM}°C"
        fi
        # 温度超限自动暂停
        if [ -n "${temp}" ] && [ "${temp}" -ge "${TEMP_PAUSE}" ] 2>/dev/null; then
            log_error "  [温度超限] GPU${i} 温度 ${temp}°C 超过暂停阈值 ${TEMP_PAUSE}°C，自动暂停！"
            TEMP_MONITOR_PAUSED=true
            break
        fi
    done
    log_info "  ${sec}s: ${temps}"
    [ "${TEMP_MONITOR_PAUSED}" = "true" ] && break
    sleep 1
done
log ""

# ========== 测试 4: CUDA 基础测试 ==========
log_info "===== 测试 4: CUDA 基础测试 ====="
if command -v nvcc >/dev/null 2>&1; then
    nvcc --version 2>&1 | tee -a "${LOG}"
fi
if [ -d "${CUDA_DIR}/bin" ]; then
    [ -f "${CUDA_DIR}/bin/deviceQuery" ] && log_info "deviceQuery:" && "${CUDA_DIR}/bin/deviceQuery" 2>&1 | tee -a "${LOG}"
    [ -f "${CUDA_DIR}/bin/bandwidthTest" ] && log_info "bandwidthTest:" && "${CUDA_DIR}/bin/bandwidthTest" 2>&1 | tee -a "${LOG}"
fi
log ""

# ========== 测试 5: gpu_burn 压力测试（带温度监控+超时暂停） ==========
log_info "===== 测试 5: gpu_burn 压力测试（${BURN_TIME}秒）====="
if [ -f "${GPUBURN_DIR}/gpu_burn" ]; then
    log_ok "使用 gpu_burn: ${GPUBURN_DIR}/gpu_burn"
    
    # 后台启动 gpu_burn
    "${GPUBURN_DIR}/gpu_burn" "${BURN_TIME}" > "${OUTDIR}/gpu_burn.log" 2>&1 &
    BURN_PID=$!
    log_info "gpu_burn 已启动 (PID: ${BURN_PID})，测试时间 ${BURN_TIME} 秒"
    
    # 温度监控循环
    START_TS="$(date +%s)"
    BURN_PAUSED=false
    while kill -0 ${BURN_PID} 2>/dev/null; do
        ELAPSED=$(( $(date +%s) - START_TS ))
        [ ${ELAPSED} -ge ${BURN_TIME} ] && break
        
        for i in $(seq 0 $((gpu_count - 1))); do
            temp="$(nvidia-smi -i ${i} --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | tr -d ' ')"
            power="$(nvidia-smi -i ${i} --query-gpu=power.draw --format=csv,noheader 2>/dev/null | tr -d ' ')"
            util="$(nvidia-smi -i ${i} --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null | tr -d ' ')"
            
            log_info "  [${ELAPSED}s] GPU${i}: 温度=${temp}°C 功耗=${power}W 利用率=${util}%"
            
            # 温度报警
            if [ -n "${temp}" ] && [ "${temp}" -ge "${TEMP_ALARM}" ] 2>/dev/null; then
                log_warn "  [温度报警] GPU${i} 温度 ${temp}°C >= ${TEMP_ALARM}°C"
            fi
            
            # 温度超限自动暂停
            if [ -n "${temp}" ] && [ "${temp}" -ge "${TEMP_PAUSE}" ] 2>/dev/null; then
                log_error "  [温度超限] GPU${i} 温度 ${temp}°C >= ${TEMP_PAUSE}°C，自动暂停 gpu_burn！"
                kill ${BURN_PID} 2>/dev/null
                BURN_PAUSED=true
                break
            fi
        done
        [ "${BURN_PAUSED}" = "true" ] && break
        sleep 5
    done
    
    # 确保 gpu_burn 结束
    kill ${BURN_PID} 2>/dev/null
    wait ${BURN_PID} 2>/dev/null
    
    if [ -f "${OUTDIR}/gpu_burn.log" ]; then
        log_info "gpu_burn 输出:"
        tail -20 "${OUTDIR}/gpu_burn.log" | tee -a "${LOG}"
    fi
    
    if [ "${BURN_PAUSED}" = "true" ]; then
        log_warn "gpu_burn 因温度超限已暂停"
    else
        log_ok "gpu_burn 测试完成"
    fi
else
    log_warn "gpu_burn 未安装，使用 nvidia-smi 压力监控代替"
    log_info "压力监控 ${BURN_TIME} 秒..."
    START_TS="$(date +%s)"
    while [ $(( $(date +%s) - START_TS )) -lt ${BURN_TIME} ]; do
        for i in $(seq 0 $((gpu_count - 1))); do
            temp="$(nvidia-smi -i ${i} --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | tr -d ' ')"
            power="$(nvidia-smi -i ${i} --query-gpu=power.draw --format=csv,noheader 2>/dev/null | tr -d ' ')"
            log_info "  GPU${i} 温度:${temp}°C 功耗:${power}W"
            if [ -n "${temp}" ] && [ "${temp}" -ge "${TEMP_ALARM}" ] 2>/dev/null; then
                log_warn "  [温度报警] GPU${i} 温度 ${temp}°C >= ${TEMP_ALARM}°C"
            fi
            if [ -n "${temp}" ] && [ "${temp}" -ge "${TEMP_PAUSE}" ] 2>/dev/null; then
                log_error "  [温度超限] GPU${i} 温度 ${temp}°C >= ${TEMP_PAUSE}°C，暂停测试！"
                break 2
            fi
        done
        sleep 5
    done
fi
log ""

# ========== 测试 6: fieldiag 原厂诊断测试（仅数据中心 GPU） ==========
log_info "===== 测试 6: fieldiag 原厂诊断测试 ====="
if [ "${FIELDIAG_AVAILABLE}" = "true" ]; then
    if [ -n "${DATACENTER_GPUS}" ]; then
        log_ok "检测到数据中心 GPU: ${DATACENTER_GPUS}"
        log_info "fieldiag 测试等级: ${FIELD_LEVEL} (1=快速 2=标准 3=完整)"
        for gpu_idx in ${DATACENTER_GPUS}; do
            log_info "GPU ${gpu_idx} 开始 fieldiag 测试..."
            # fieldiag 执行
            "${FIELDIAG_BIN}" -g ${gpu_idx} -l ${FIELD_LEVEL} 2>&1 | tee -a "${LOG}" || {
                # 某些版本参数不同
                "${FIELDIAG_BIN}" -gpu ${gpu_idx} -level ${FIELD_LEVEL} 2>&1 | tee -a "${LOG}" || {
                    "${FIELDIAG_BIN}" ${gpu_idx} ${FIELD_LEVEL} 2>&1 | tee -a "${LOG}" || log_warn "GPU ${gpu_idx} fieldiag 执行失败"
                }
            }
            log_ok "GPU ${gpu_idx} fieldiag 测试完成"
        done
    else
        log_info "没有数据中心 GPU，跳过 fieldiag 测试"
    fi
else
    log_warn "fieldiag 未安装，跳过原厂诊断测试"
    log_info "  PCIe 插槽 GPU 不需要 fieldiag"
    if [ -n "${DATACENTER_GPUS}" ]; then
        log_warn "  检测到数据中心 GPU ${DATACENTER_GPUS}，建议安装 fieldiag 进行原厂诊断"
    fi
fi
log ""

# ========== 生成测试报告 ==========
log_info "===== 生成测试报告 ====="
REPORT="${OUTDIR}/report.txt"
{
    echo "============================================"
    echo " NVIDIA GPU 测试报告"
    echo " 日期: $(date)"
    echo " 系统: $(lsb_release -ds 2>/dev/null || echo 'Ubuntu')"
    echo " 内核: $(uname -r)"
    echo "============================================"
    echo ""
    echo "测试参数:"
    echo "  GPU burn 时间: ${BURN_TIME} 秒"
    echo "  温度报警阈值: ${TEMP_ALARM}°C"
    echo "  温度暂停阈值: ${TEMP_PAUSE}°C"
    echo "  fieldiag 等级: ${FIELD_LEVEL}"
    echo ""
    echo "============================================"
    echo "1. GPU 基本信息"
    echo "============================================"
    nvidia-smi 2>&1
    echo ""
    echo "============================================"
    echo "2. GPU 详细信息"
    echo "============================================"
    for i in $(seq 0 $((gpu_count - 1))); do
        echo "--- GPU ${i} ---"
        nvidia-smi -i ${i} --query-gpu=index,name,driver_version,memory.total,memory.free,temperature.gpu,power.draw,power.limit,clocks.current.sm,clocks.current.mem,pstate,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv 2>&1
        echo ""
    done
    echo "============================================"
    echo "3. PCIe 链路状态"
    echo "============================================"
    for i in $(seq 0 $((gpu_count - 1))); do
        echo "--- GPU ${i} ---"
        nvidia-smi -i ${i} --query-gpu=index,name,pcie.link.gen.current,pcie.link.width.current,pcie.link.replay.errors,pcie.link.rx.errors,pcie.link.tx.errors --format=csv 2>&1
        echo ""
    done
    echo "============================================"
    echo "4. 温度监控数据"
    echo "============================================"
    echo "见 test.log 中的温度监控记录"
    echo ""
    echo "============================================"
    echo "5. gpu_burn 压力测试"
    echo "============================================"
    if [ -f "${OUTDIR}/gpu_burn.log" ]; then
        cat "${OUTDIR}/gpu_burn.log"
    else
        echo "见 test.log 中的压力测试数据"
    fi
    echo ""
    echo "============================================"
    echo "6. fieldiag 原厂诊断"
    echo "============================================"
    if [ "${FIELDIAG_AVAILABLE}" = "true" ] && [ -n "${DATACENTER_GPUS}" ]; then
        echo "fieldiag 已执行，见 test.log 中的详细输出"
    else
        echo "fieldiag 未执行（未安装或无数据中心 GPU）"
    fi
    echo ""
    echo "============================================"
    echo "7. GPU 分类"
    echo "============================================"
    echo "数据中心 GPU (H100-B300): ${DATACENTER_GPUS:-无}"
    echo "PCIe GPU: ${PCIE_GPUS:-无}"
    echo ""
    echo "============================================"
    echo "8. 结论"
    echo "============================================"
    echo "  共检测到 ${gpu_count} 张 GPU"
    echo "  测试时间: $(date)"
    echo "  详细日志: ${LOG}"
    echo "  gpu_burn 日志: ${OUTDIR}/gpu_burn.log"
} > "${REPORT}"

log ""
log "============================================"
log_ok "全部测试完成！"
log_ok "报告: ${REPORT}"
log_ok "日志: ${LOG}"
if [ -f "${OUTDIR}/gpu_burn.log" ]; then
    log_ok "gpu_burn: ${OUTDIR}/gpu_burn.log"
fi
log "============================================"
log ""
log "测试报告内容:"
cat "${REPORT}"