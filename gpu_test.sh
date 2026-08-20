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
log " NVIDIA GPU 测试脚本（纯测试，不改系统）"
log " 日志: ${LOG}"
log "============================================"

# ========== 检查驱动 ==========
if ! command -v nvidia-smi >/dev/null 2>&1; then
    log_error "nvidia-smi 不存在！请先运行: ./install_nvidia_driver.sh"
    exit 1
fi
if ! nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_error "未检测到 GPU！可能需要重启: sudo reboot"
    exit 1
fi
log_ok "NVIDIA 驱动正常"

# ========== 用户交互：测试参数设置 ==========
log_info "请设置测试参数（直接输入数字回车确认）:"

read -p "GPU burn 压力测试时间（秒，默认300）: " BURN_TIME
BURN_TIME="${BURN_TIME:-300}"

read -p "温度报警阈值（°C，默认85）: " TEMP_ALARM
TEMP_ALARM="${TEMP_ALARM:-85}"

read -p "温度超限自动暂停阈值（°C，默认90）: " TEMP_PAUSE
TEMP_PAUSE="${TEMP_PAUSE:-90}"

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

# ========== 安装测试工具（不改系统配置） ==========
log_info "检查测试工具..."

# gpu_burn
if [ -f "${GPUBURN_DIR}/gpu_burn" ]; then
    log_ok "gpu_burn 已就绪: ${GPUBURN_DIR}/gpu_burn"
else
    log_info "安装 gpu_burn..."
    mkdir -p "${GPUBURN_DIR}"
    apt-get install -y git 2>/dev/null || true
    if git clone https://github.com/wilicc/gpu-burn.git "${GPUBURN_DIR}/src" 2>/dev/null; then
        cd "${GPUBURN_DIR}/src"
        make 2>&1 | tee -a "${LOG}"
        cp -f gpu_burn "${GPUBURN_DIR}/" 2>/dev/null || true
        cp -f compare "${GPUBURN_DIR}/" 2>/dev/null || true
        cd /
        log_ok "gpu_burn 安装完成"
    else
        log_warn "无法下载 gpu_burn，将用 nvidia-smi 监控代替"
    fi
fi

# fieldiag
FIELDIAG_AVAILABLE=false
FIELDIAG_BIN="${FIELDIAG_DIR}/fieldiag"
if [ -f "${FIELDIAG_BIN}" ]; then
    FIELDIAG_AVAILABLE=true
    log_ok "fieldiag 已就绪: ${FIELDIAG_BIN}"
else
    log_warn "fieldiag 未找到"
    log_info "  fieldiag 是 NVIDIA 原厂诊断工具，需从 NVIDIA 官网下载"
    log_info "  如已有文件，放到: ${FIELDIAG_DIR}/"
    log_info "  PCIe 插槽 GPU 不需要 fieldiag，会自动跳过"
fi

# ========== GPU 检测和分类 ==========
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

DATACENTER_GPUS=""
PCIE_GPUS=""
gpu_index=0

while IFS= read -r line; do
    gpu_name="$(echo "${line}" | sed 's/GPU .*: //;s/ (UUID.*//')"
    log_info "GPU ${gpu_index}: ${gpu_name}"
    if echo "${gpu_name}" | grep -qiE 'H100|H200|A100|A800|H800|B100|B200|B300|L40S?|L40|V100'; then
        DATACENTER_GPUS="${DATACENTER_GPUS} ${gpu_index}"
        log_info "  -> 数据中心 GPU，适用 fieldiag"
    else
        PCIE_GPUS="${PCIE_GPUS} ${gpu_index}"
        log_info "  -> PCIe GPU，跳过 fieldiag"
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
        if [ -n "${temp}" ] && [ "${temp}" -ge "${TEMP_ALARM}" ] 2>/dev/null; then
            log_warn "  [温度报警] GPU${i} 温度 ${temp}°C 超过报警阈值 ${TEMP_ALARM}°C"
        fi
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
    "${GPUBURN_DIR}/gpu_burn" "${BURN_TIME}" > "${OUTDIR}/gpu_burn.log" 2>&1 &
    BURN_PID=$!
    log_info "gpu_burn 已启动 (PID: ${BURN_PID})，测试时间 ${BURN_TIME} 秒"

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
            if [ -n "${temp}" ] && [ "${temp}" -ge "${TEMP_ALARM}" ] 2>/dev/null; then
                log_warn "  [温度报警] GPU${i} 温度 ${temp}°C >= ${TEMP_ALARM}°C"
            fi
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
            "${FIELDIAG_BIN}" -g ${gpu_idx} -l ${FIELD_LEVEL} 2>&1 | tee -a "${LOG}" || {
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