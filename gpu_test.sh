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

gpu_count="$(nvidia-smi -L 2>/dev/null | wc -l || echo 0)"
log_info "检测到 ${gpu_count} 张 GPU"
if [ "${gpu_count}" -eq 0 ]; then
    log_error "没有检测到 NVIDIA GPU！请先安装驱动"
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
    if [ -f "${CUDA_BIN}/deviceQuery" ]; then
        log_info "运行 deviceQuery..."
        "${CUDA_BIN}/deviceQuery" 2>&1 | tee -a "${LOG}"
    fi
    if [ -f "${CUDA_BIN}/bandwidthTest" ]; then
        log_info "运行 bandwidthTest..."
        "${CUDA_BIN}/bandwidthTest" 2>&1 | tee -a "${LOG}"
    fi
fi

log_info "===== GPU 压力测试 (60秒) ====="
for i in $(seq 0 $((gpu_count - 1))); do
    log_info "GPU ${i} 满载测试..."
    nvidia-smi -i ${i} -lgttl 2>&1 | head -1
    log_info "  预热 5 秒..."
    sleep 5
    log_info "  满载 60 秒..."
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
    echo "  测试完成，共检测到 ${gpu_count} 张 GPU"
    echo "  详细日志: ${LOG}"
} > "${REPORT}"

log_ok "============================================"
log_ok "测试完成！"
log_ok "报告: ${REPORT}"
log_ok "日志: ${LOG}"
log_ok "============================================"

cat "${REPORT}"