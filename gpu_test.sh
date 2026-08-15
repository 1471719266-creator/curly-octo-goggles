#!/bin/bash
#===============================================================================
# NVIDIA GPU 售后服务自动化测试脚本
# 支持 Ubuntu 24.04 LTS，兼容 H100 ~ B300 全系列数据中心/消费级 GPU
# 测试工具：NVIDIA CUDA Toolkit (官方) + DCGM (官方数据中心诊断)
#===============================================================================
set -o pipefail

# =========================================
# 配置区（集中管理，便于售后服务追溯）
# =========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/gpu_test_results_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${OUTPUT_DIR}/test.log"
RAW_DATA_DIR="${OUTPUT_DIR}/raw_data"
CUDA_VERSION="12.6.1"  # 支持 H100/B200/B300 等最新GPU的稳定CUDA版本
DCGM_VERSION="3.4.1"
STRESS_DURATION_SEC=60   # 压力测试时长(秒)，售后服务建议60~300秒

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# =========================================
# 初始化
# =========================================
init() {
    mkdir -p "${OUTPUT_DIR}" "${RAW_DATA_DIR}"
    touch "${LOG_FILE}"
    exec 2> >(tee -a "${LOG_FILE}" >&2)
}

log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')][${level}] $*"
    echo -e "${msg}" | tee -a "${LOG_FILE}"
}

log_info()  { log "INFO"  "${BLUE}$*${NC}"; }
log_ok()    { log "OK"    "${GREEN}$*${NC}"; }
log_warn()  { log "WARN"  "${YELLOW}$*${NC}"; }
log_error() { log "ERROR" "${RED}$*${NC}"; }

# 保存原始命令输出到文件，便于报告生成溯源
save_raw() {
    local name="$1"; shift
    local dest="${RAW_DATA_DIR}/${name}.txt"
    "$@" > "${dest}" 2>&1 || true
    log_info "原始输出已保存: ${dest}"
    echo "${dest}"
}

# =========================================
# 0. 安装系统级依赖（wget/curl/git/lspci/python3 等基础工具）
# =========================================
install_system_deps() {
    log_info "========== 0. 安装系统级依赖工具 =========="

    local deps_missing=()
    command -v wget    &>/dev/null || deps_missing+=("wget")
    command -v curl    &>/dev/null || deps_missing+=("curl")
    command -v git     &>/dev/null || deps_missing+=("git")
    command -v lspci   &>/dev/null || deps_missing+=("pciutils")
    command -v python3 &>/dev/null || deps_missing+=("python3")
    command -v make    &>/dev/null || deps_missing+=("make")
    command -v gcc     &>/dev/null || deps_missing+=("gcc")

    if [ ${#deps_missing[@]} -gt 0 ]; then
        log_info "缺少依赖: ${deps_missing[*]}，正在安装..."
        sudo apt-get update -y >> "${LOG_FILE}" 2>&1
        sudo apt-get install -y "${deps_missing[@]}" >> "${LOG_FILE}" 2>&1
        if [ $? -eq 0 ]; then
            log_ok "系统依赖安装完成: ${deps_missing[*]}"
        else
            log_error "系统依赖安装失败，请手动执行: sudo apt-get install ${deps_missing[*]}"
            exit 1
        fi
    else
        log_ok "系统依赖工具已就绪（wget/curl/git/lspci/python3/make/gcc）"
    fi

    # 确保 build-essential 完整（编译 cuda-samples 需要）
    if ! dpkg -s build-essential &>/dev/null; then
        log_info "安装 build-essential（编译环境）..."
        sudo apt-get install -y build-essential >> "${LOG_FILE}" 2>&1
    fi
}

# =========================================
# 1. 系统环境检测
# =========================================
check_system() {
    log_info "========== 1. 系统环境检测 =========="

    # 检测Ubuntu版本
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        log_info "操作系统: ${PRETTY_NAME}"
        if [[ "${VERSION_ID}" != "24.04" ]]; then
            log_warn "当前非 Ubuntu 24.04，脚本会尝试继续执行，但不保证完全兼容"
        fi
    fi

    log_info "内核版本: $(uname -r)"
    log_info "主机名: $(hostname)"
    log_info "架构: $(uname -m)"

    # 检测PCIe GPU设备
    log_info "扫描PCIe总线上的NVIDIA GPU..."
    VGA_LIST=$(lspci | grep -i nvidia || true)
    if [ -z "${VGA_LIST}" ]; then
        log_error "未在PCIe总线上检测到任何NVIDIA GPU设备！"
        log_error "请检查：1) GPU是否正确插入PCIe插槽 2) 电源是否连接 3) BIOS中是否禁用了GPU"
        exit 1
    fi
    log_ok "检测到以下PCIe GPU设备："
    echo "${VGA_LIST}" | tee -a "${LOG_FILE}"

    # 检测IOMMU/ACS（多GPU P2P需要）
    if [ -d /sys/kernel/iommu_groups ]; then
        IOMMU_COUNT=$(find /sys/kernel/iommu_groups -type l 2>/dev/null | wc -l)
        log_info "IOMMU组数量: ${IOMMU_COUNT}"
    fi
}

# =========================================
# 2. NVIDIA 驱动检测与安装
# =========================================
check_nvidia_driver() {
    log_info "========== 2. NVIDIA 驱动检测 =========="

    if command -v nvidia-smi &>/dev/null; then
        DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
        log_ok "已安装 NVIDIA 驱动版本: ${DRIVER_VER}"
        save_raw "nvidia_smi_initial" nvidia-smi
        return 0
    fi

    log_warn "未检测到 nvidia-smi，开始自动安装 NVIDIA 驱动..."

    # 检查是否有apt源更新
    sudo apt-get update -y >> "${LOG_FILE}" 2>&1

    # 安装ubuntu-drivers工具，自动推荐驱动
    sudo apt-get install -y ubuntu-drivers-common software-properties-common dkms build-essential >> "${LOG_FILE}" 2>&1

    # 使用官方proprietary GPU驱动PPA（包含最新数据中心驱动）
    sudo add-apt-repository -y ppa:graphics-drivers/ppa >> "${LOG_FILE}" 2>&1
    sudo apt-get update -y >> "${LOG_FILE}" 2>&1

    # 自动安装推荐的驱动（优先选择-server版本用于数据中心GPU）
    log_info "正在检测推荐驱动版本..."
    RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep -i "recommended" | awk '{print $3}' | head -n1)
    if [ -z "${RECOMMENDED}" ]; then
        RECOMMENDED="nvidia-driver-560-server"  # 默认回退到支持H100/B300的服务器驱动
    fi
    log_info "即将安装驱动: ${RECOMMENDED}"
    sudo apt-get install -y "${RECOMMENDED}" dkms >> "${LOG_FILE}" 2>&1

    if [ $? -eq 0 ]; then
        log_ok "NVIDIA 驱动安装成功，建议重启系统后再次运行此脚本"
        log_warn "提示：部分服务器需在BIOS中禁用Secure Boot才能加载驱动模块"
    else
        log_error "驱动安装失败，请检查日志: ${LOG_FILE}"
        exit 1
    fi
}

# =========================================
# 3. CUDA Toolkit 下载与安装（官方权威测试工具来源）
# =========================================
install_cuda_toolkit() {
    log_info "========== 3. CUDA Toolkit 安装 =========="

    # 检查nvcc是否已存在
    if command -v nvcc &>/dev/null; then
        CUDA_VER=$(nvcc --version | grep -oP "release \K[0-9]+\.[0-9]+" | head -n1)
        log_ok "已安装 CUDA Toolkit 版本: ${CUDA_VER}"
    else
        log_info "开始下载并安装 CUDA Toolkit ${CUDA_VERSION}（官方runfile方式，避免驱动冲突）..."

        CUDA_RUNFILE="cuda_${CUDA_VERSION}_560.35.05_linux.run"
        CUDA_URL="https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/${CUDA_RUNFILE}"

        if [ ! -f "/tmp/${CUDA_RUNFILE}" ]; then
            log_info "正在下载 CUDA Toolkit，请耐心等待（约4GB）..."
            wget -q --show-progress -O "/tmp/${CUDA_RUNFILE}" "${CUDA_URL}" 2>&1 | tee -a "${LOG_FILE}"
            if [ $? -ne 0 ]; then
                log_error "CUDA下载失败，尝试使用apt方式安装..."
                # apt fallback
                wget -qO /tmp/cuda-keyring.deb \
                    "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"
                sudo dpkg -i /tmp/cuda-keyring.deb >> "${LOG_FILE}" 2>&1
                sudo apt-get update -y >> "${LOG_FILE}" 2>&1
                sudo apt-get install -y "cuda-toolkit-${CUDA_VERSION//./-}" >> "${LOG_FILE}" 2>&1
            fi
        fi

        if [ -f "/tmp/${CUDA_RUNFILE}" ]; then
            chmod +x "/tmp/${CUDA_RUNFILE}"
            log_info "正在以静默方式安装 CUDA Toolkit（不装驱动，只装工具链和samples）..."
            sudo "/tmp/${CUDA_RUNFILE}" --silent --toolkit --samples --samplespath=/usr/local/cuda/samples \
                --override >> "${LOG_FILE}" 2>&1 || {
                log_warn "runfile方式可能遇到问题，尝试仅安装toolkit包"
            }
        fi
    fi

    # 设置PATH
    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"
    echo 'export PATH="/usr/local/cuda/bin:$PATH"' | sudo tee /etc/profile.d/cuda.sh >/dev/null
    echo 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' | sudo tee -a /etc/profile.d/cuda.sh >/dev/null

    # 确认nvcc
    if command -v nvcc &>/dev/null; then
        log_ok "CUDA Toolkit 安装完成: $(nvcc --version | grep release | tr -s ' ')"
    else
        log_error "CUDA Toolkit 安装失败，请检查网络或手动安装"
        exit 1
    fi

    # 编译 cuda-samples 中的官方测试工具
    compile_cuda_samples
}

compile_cuda_samples() {
    log_info "编译 CUDA Samples 中的官方权威测试工具..."

    SAMPLES_SRC="/usr/local/cuda/samples"
    BIN_DIR="${OUTPUT_DIR}/cuda_samples_bin"
    mkdir -p "${BIN_DIR}"

    # 需要编译的官方测试工具清单
    local -a targets=(
        "1_Utilities/deviceQuery"
        "1_Utilities/bandwidthTest"
        "1_Utilities/p2pBandwidthLatencyTest"
        "1_Utilities/topologyQuery"
        "0_Simple/matrixMul"
        "5_Simulations/nbody"
    )

    for target in "${targets[@]}"; do
        local name=$(basename "${target}")
        local src_path="${SAMPLES_SRC}/${target}"
        if [ -d "${src_path}" ]; then
            log_info "编译: ${name}"
            if make -C "${src_path}" >> "${LOG_FILE}" 2>&1; then
                cp "${src_path}/${name}" "${BIN_DIR}/" 2>/dev/null || true
            fi
        else
            # 新版cuda把samples拆分到独立包，尝试用git获取
            log_warn "samples目录不存在，尝试从GitHub获取..."
            if [ ! -d "/tmp/cuda-samples" ]; then
                git clone --depth 1 https://github.com/NVIDIA/cuda-samples.git /tmp/cuda-samples >> "${LOG_FILE}" 2>&1
            fi
            src_path="/tmp/cuda-samples/Samples/${target}"
            if [ -d "${src_path}" ]; then
                make -C "${src_path}" SMS="" >> "${LOG_FILE}" 2>&1
                cp "${src_path}/${name}" "${BIN_DIR}/" 2>/dev/null || true
            fi
        fi
    done

    log_ok "可用的测试工具: $(ls -1 "${BIN_DIR}" 2>/dev/null | tr '\n' ', ')"
    echo "${BIN_DIR}" > "${OUTPUT_DIR}/cuda_bin_dir.txt"
}

# =========================================
# 4. NVIDIA DCGM 安装（官方数据中心权威诊断工具）
# =========================================
install_dcgm() {
    log_info "========== 4. NVIDIA DCGM 数据中心诊断工具安装 =========="

    if command -v dcgmi &>/dev/null; then
        log_ok "DCGM 已安装: $(dcgmi --version 2>&1 | head -n1)"
        return 0
    fi

    log_info "安装 NVIDIA DCGM（官方数据中心GPU权威诊断工具）..."

    # DCGM 官方仓库
    curl -s -L https://nvidia.github.io/DCGM/gpgkey | sudo apt-key add - >> "${LOG_FILE}" 2>&1
    OS_VER="ubuntu24.04"
    curl -s -L "https://nvidia.github.io/DCGM/${OS_VER}/x86_64/DCGM.list" | \
        sudo tee /etc/apt/sources.list.d/dcgm.list >/dev/null
    sudo apt-get update -y >> "${LOG_FILE}" 2>&1
    sudo apt-get install -y datacenter-gpu-manager >> "${LOG_FILE}" 2>&1

    # 启动DCGM服务
    sudo systemctl enable --now nvidia-dcgm.service >> "${LOG_FILE}" 2>&1 || true
    sleep 2

    if command -v dcgmi &>/dev/null; then
        log_ok "DCGM 安装并启动成功"
    else
        log_warn "DCGM 安装失败（消费级GPU可能不支持），将使用nvidia-smi替代"
    fi
}

# =========================================
# 4.5 下载编译原厂质检工具：gpu-burn + cuda_memtest
#   - gpu-burn: 满载烧机+正确性校验（矩阵乘法结果与CPU基准比对）
#   - cuda_memtest: 显存10种模式主动写入-读出-校验（行业级显存质检标准）
# =========================================
install_factory_tools() {
    log_info "========== 4.5 下载编译原厂质检工具（gpu-burn + cuda_memtest） =========="

    local FACTORY_BIN="${OUTPUT_DIR}/factory_tools_bin"
    mkdir -p "${FACTORY_BIN}"
    echo "${FACTORY_BIN}" > "${OUTPUT_DIR}/factory_bin_dir.txt"

    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"

    # ---- gpu-burn: 满载烧机 + 正确性校验 ----
    local GB_DIR="/tmp/gpu-burn"
    if [ ! -x "${GB_DIR}/gpu_burn" ]; then
        log_info "[1/2] 下载编译 gpu-burn（满载烧机+正确性校验）..."
        rm -rf "${GB_DIR}"
        git clone --depth 1 https://github.com/wilicc/gpu-burn.git "${GB_DIR}" >> "${LOG_FILE}" 2>&1
        if [ $? -ne 0 ]; then
            log_warn "gpu-burn git clone 失败，尝试备用地址..."
            git clone --depth 1 https://gitclone.com/github.com/wilicc/gpu-burn.git "${GB_DIR}" >> "${LOG_FILE}" 2>&1 || true
        fi
        if [ -d "${GB_DIR}" ]; then
            # 修改Makefile指定CUDA路径
            sed -i "s|CUDA_PATH?=.*|CUDA_PATH?=/usr/local/cuda|g" "${GB_DIR}/Makefile" 2>/dev/null || true
            make -C "${GB_DIR}" >> "${LOG_FILE}" 2>&1
            if [ -x "${GB_DIR}/gpu_burn" ]; then
                cp "${GB_DIR}/gpu_burn" "${FACTORY_BIN}/"
                log_ok "gpu-burn 编译成功"
            else
                log_warn "gpu-burn 编译失败，跳过（不影响其他测试）"
            fi
        fi
    else
        log_ok "gpu-burn 已编译，直接复用"
        cp "${GB_DIR}/gpu_burn" "${FACTORY_BIN}/" 2>/dev/null || true
    fi

    # ---- cuda_memtest: 显存10种模式主动校验 ----
    local CM_DIR="/tmp/cuda_memtest"
    if [ ! -x "${CM_DIR}/cuda_memtest" ] && [ ! -x "${CM_DIR}/cuda_memtest-1.2.3/cuda_memtest" ]; then
        log_info "[2/2] 下载编译 cuda_memtest（显存10种模式主动写入-读出-校验）..."
        rm -rf "${CM_DIR}"
        git clone --depth 1 https://github.com/ComputationalRadiationPhysics/cuda_memtest.git "${CM_DIR}" >> "${LOG_FILE}" 2>&1
        if [ $? -ne 0 ]; then
            log_warn "cuda_memtest git clone 失败，尝试备用地址..."
            git clone --depth 1 https://gitclone.com/github.com/ComputationalRadiationPhysics/cuda_memtest.git "${CM_DIR}" >> "${LOG_FILE}" 2>&1 || true
        fi
        if [ -d "${CM_DIR}" ]; then
            sed -i "s|CUDA_DIR.*=.*|CUDA_DIR = /usr/local/cuda|g" "${CM_DIR}/Makefile" 2>/dev/null || true
            make -C "${CM_DIR}" >> "${LOG_FILE}" 2>&1
            local cm_bin=$(find "${CM_DIR}" -name "cuda_memtest" -type f -executable 2>/dev/null | head -n1)
            if [ -n "${cm_bin}" ]; then
                cp "${cm_bin}" "${FACTORY_BIN}/cuda_memtest"
                log_ok "cuda_memtest 编译成功"
            else
                log_warn "cuda_memtest 编译失败，跳过（不影响其他测试）"
            fi
        fi
    else
        log_ok "cuda_memtest 已编译，直接复用"
        local cm_bin=$(find "${CM_DIR}" -name "cuda_memtest" -type f -executable 2>/dev/null | head -n1)
        [ -n "${cm_bin}" ] && cp "${cm_bin}" "${FACTORY_BIN}/cuda_memtest" 2>/dev/null || true
    fi

    log_ok "原厂质检工具就绪: $(ls -1 "${FACTORY_BIN}" 2>/dev/null | tr '\n' ', ')"
}

# =========================================
# 5. GPU 枚举与基础信息采集（门禁检查）
# =========================================
enumerate_gpus() {
    log_info "========== 5. GPU 设备枚举（可用性门禁） =========="

    GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -n1 || echo 0)
    if [ "${GPU_COUNT}" -eq 0 ] 2>/dev/null; then
        # 兼容不同驱动版本
        GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
    fi

    if [ "${GPU_COUNT}" -eq 0 ]; then
        log_error "GPU可用性门禁未通过：nvidia-smi无法枚举GPU，停止所有测试"
        log_error "请检查驱动是否正确加载（lsmod | grep nvidia）、是否需要重启系统"
        save_raw "nvidia_smi_L" nvidia-smi -L
        save_raw "lsmod_nvidia" bash -c "lsmod | grep -i nvidia"
        save_raw "dmesg_nvidia" bash -c "dmesg | grep -i nvidia | tail -50"
        exit 1
    fi

    log_ok "GPU可用性门禁通过，共检测到 ${GPU_COUNT} 块 GPU"
    echo "${GPU_COUNT}" > "${OUTPUT_DIR}/gpu_count.txt"

    # 输出每块GPU的基础信息
    nvidia-smi --query-gpu=index,name,pci.bus_id,driver_version,pstate,pcie.link.gen.max,pcie.link.width.max,vbios_version,serial,uuid,compute_mode \
        --format=csv | tee "${RAW_DATA_DIR}/gpu_basic_info.csv" | tee -a "${LOG_FILE}"

    # 保存详细的 nvidia-smi 输出
    save_raw "nvidia_smi_full" nvidia-smi -q -x  # XML格式便于解析

    # PCIe 拓扑信息
    save_raw "nvidia_smi_topology" nvidia-smi topo -m
}

# =========================================
# 6. 官方测试一：deviceQuery（CUDA能力全量枚举）
# =========================================
test_device_query() {
    log_info "========== 6. CUDA deviceQuery 官方测试 =========="
    local bin_dir
    bin_dir=$(cat "${OUTPUT_DIR}/cuda_bin_dir.txt" 2>/dev/null)
    if [ -x "${bin_dir}/deviceQuery" ]; then
        save_raw "deviceQuery" "${bin_dir}/deviceQuery"
        log_ok "deviceQuery 测试完成"
    else
        log_warn "deviceQuery 未编译，使用 nvidia-smi 替代查询"
    fi
}

# =========================================
# 7. 官方测试二：bandwidthTest（PCIe 带宽 Host<->Device）
# =========================================
test_bandwidth() {
    log_info "========== 7. PCIe 带宽测试（官方 bandwidthTest） =========="
    local bin_dir
    bin_dir=$(cat "${OUTPUT_DIR}/cuda_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    if [ -x "${bin_dir}/bandwidthTest" ]; then
        for (( i=0; i<gpu_count; i++ )); do
            log_info "测试 GPU ${i} 的PCIe带宽..."
            CUDA_VISIBLE_DEVICES=${i} save_raw "bandwidthTest_gpu${i}" \
                "${bin_dir}/bandwidthTest" --device=${i} --memory=pinned --mode=range --csv
            log_info "GPU ${i} 带宽测试完成"
        done
        log_ok "PCIe带宽测试全部完成（结果包含 H2D/D2H/D2D）"
    else
        log_warn "bandwidthTest 不可用，跳过PCIe带宽测试"
    fi
}

# =========================================
# 8. 官方测试三：p2pBandwidthLatencyTest（多GPU P2P通信）
# =========================================
test_p2p() {
    log_info "========== 8. 多GPU P2P 带宽/延迟测试（官方 p2pBandwidthLatencyTest） =========="
    local bin_dir
    bin_dir=$(cat "${OUTPUT_DIR}/cuda_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    if [ "${gpu_count}" -lt 2 ]; then
        log_info "单GPU系统，跳过P2P测试"
        return
    fi

    if [ -x "${bin_dir}/p2pBandwidthLatencyTest" ]; then
        save_raw "p2pBandwidthLatencyTest" "${bin_dir}/p2pBandwidthLatencyTest"

        # topologyQuery 辅助诊断拓扑
        if [ -x "${bin_dir}/topologyQuery" ]; then
            save_raw "topologyQuery" "${bin_dir}/topologyQuery"
        fi
        log_ok "P2P测试完成（含带宽/延迟矩阵）"
    else
        log_warn "p2pBandwidthLatencyTest 不可用，使用 nvidia-smi topo 替代"
        save_raw "nvidia_smi_p2p" nvidia-smi p2p -s 2>/dev/null || true
    fi
}

# =========================================
# 9. CUDA 计算性能基准：nbody + matrixMul（官方）
# =========================================
test_cuda_perf() {
    log_info "========== 9. CUDA 计算性能基准测试 =========="
    local bin_dir
    bin_dir=$(cat "${OUTPUT_DIR}/cuda_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    for (( i=0; i<gpu_count; i++ )); do
        # nbody 模拟（衡量FP32/FP64算力）
        if [ -x "${bin_dir}/nbody" ]; then
            log_info "GPU ${i}: 运行 nbody 计算性能基准..."
            CUDA_VISIBLE_DEVICES=${i} save_raw "nbody_gpu${i}" \
                "${bin_dir}/nbody" -benchmark -fp64 -n=16384
            CUDA_VISIBLE_DEVICES=${i} save_raw "nbody_fp32_gpu${i}" \
                "${bin_dir}/nbody" -benchmark -fp32 -n=32768
        fi

        # matrixMul 矩阵乘法基准
        if [ -x "${bin_dir}/matrixMul" ]; then
            log_info "GPU ${i}: 运行 matrixMul 矩阵乘法基准..."
            CUDA_VISIBLE_DEVICES=${i} save_raw "matrixMul_gpu${i}" "${bin_dir}/matrixMul" -wA=1024 -hA=1024 -wB=1024 -hB=1024
        fi
    done
    log_ok "CUDA计算性能基准测试完成"
}

# =========================================
# 10. 温度/功耗/稳定性压力测试（售后服务核心项）
# =========================================
test_stress_thermal() {
    log_info "========== 10. 温度/功耗/稳定性压力测试（${STRESS_DURATION_SEC}秒） =========="
    local bin_dir
    bin_dir=$(cat "${OUTPUT_DIR}/cuda_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    # 启动后台监控（每秒采样一次温度/功耗/风扇/显存）
    log_info "启动 nvidia-smi 后台监控（每秒采样）..."
    nvidia-smi --query-gpu=timestamp,index,name,temperature.gpu,power.draw,fan.speed,utilization.gpu,utilization.memory,memory.used,memory.total,clocks.current.graphics,clocks.current.memory,pstate \
        --format=csv -l 1 -f "${RAW_DATA_DIR}/gpu_monitor_during_stress.csv" &
    MONITOR_PID=$!

    # 启动压力负载（每个GPU跑nbody大负载持续指定时长）
    local -a stress_pids=()
    if [ -x "${bin_dir}/nbody" ]; then
        for (( i=0; i<gpu_count; i++ )); do
            log_info "GPU ${i}: 启动压力负载（${STRESS_DURATION_SEC}秒）..."
            (
                timeout "${STRESS_DURATION_SEC}" "${bin_dir}/nbody" \
                    -benchmark -fp32 -n=65536 -numDevices=1 -device=${i} -iterations=99999999 \
                    > "${RAW_DATA_DIR}/stress_nbody_gpu${i}.log" 2>&1
            ) &
            stress_pids+=($!)
        done
    else
        # fallback: 使用gpu-burn或自己的简单CUDA负载，这里用nvidia-smi dmon监控空转
        log_warn "nbody不可用，使用轻量级监控模式"
        sleep "${STRESS_DURATION_SEC}"
    fi

    # 等待所有压力进程结束（加上超时保护）
    local max_wait=$((STRESS_DURATION_SEC + 60))
    local waited=0
    while [ ${waited} -lt ${max_wait} ]; do
        local all_done=1
        for pid in "${stress_pids[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then all_done=0; break; fi
        done
        [ ${all_done} -eq 1 ] && break
        sleep 2; waited=$((waited + 2))
    done

    # 停止监控
    kill "${MONITOR_PID}" 2>/dev/null; wait "${MONITOR_PID}" 2>/dev/null

    # 分析温度/功耗结果
    log_info "压力测试完成，分析温度数据..."
    python3 - <<'PYEOF' >> "${LOG_FILE}" 2>&1
import csv, json, os
csv_path = os.environ.get('CSV_PATH')
if os.path.exists(csv_path):
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    if rows:
        gpus = {}
        for r in rows:
            idx = r.get(' index', r.get('index', '0')).strip()
            gpus.setdefault(idx, {'temps': [], 'powers': [], 'fans': []})
            for key, field in [('temps', ' temperature.gpu'), ('powers', ' power.draw [W]'), ('fans', ' fan.speed [%]')]:
                val = r.get(field)
                if val and 'N/A' not in val:
                    try:
                        num = float(''.join(c for c in val if c.isdigit() or c in '.-'))
                        gpus[idx][key].append(num)
                    except: pass
        print("=== 压力测试温度/功耗摘要 ===")
        for idx, data in sorted(gpus.items()):
            t = data['temps']; p = data['powers']
            print(f"GPU {idx}: 温度 MIN/AVG/MAX = {min(t):.1f}/{sum(t)/len(t):.1f}/{max(t):.1f} C" if t else f"GPU {idx}: 温度无数据")
            print(f"GPU {idx}: 功耗 MIN/AVG/MAX = {min(p):.1f}/{sum(p)/len(p):.1f}/{max(p):.1f} W" if p else f"GPU {idx}: 功耗无数据")
PYEOF
    CSV_PATH="${RAW_DATA_DIR}/gpu_monitor_during_stress.csv" python3 - <<'PYEOF'
import csv, os
csv_path = os.environ['CSV_PATH']
if os.path.exists(csv_path):
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    gpus = {}
    for r in rows:
        idx = list(r.values())[1].strip() if len(list(r.values()))>1 else '0'
        gpus.setdefault(idx, [])
        try:
            t = float([v for k,v in r.items() if 'temp' in k.lower()][0].split()[0])
            gpus[idx].append(t)
        except: pass
    print("=== 温度摘要（简化解析）===")
    for idx, temps in sorted(gpus.items()):
        if temps:
            print(f"GPU {idx}: MIN {min(temps):.1f}C / AVG {sum(temps)/len(temps):.1f}C / MAX {max(temps):.1f}C")
PYEOF

    # 保存压力测试前后的 nvidia-smi
    save_raw "nvidia_smi_after_stress" nvidia-smi

    log_ok "温度/功耗/稳定性压力测试完成"
}

# =========================================
# 11. DCGM 诊断（如果可用）—— 官方数据中心级完整测试
# =========================================
test_dcgm() {
    log_info "========== 11. NVIDIA DCGM 官方数据中心诊断 =========="
    if ! command -v dcgmi &>/dev/null; then
        log_warn "DCGM 不可用，跳过（消费级GPU正常现象）"
        return
    fi

    # 运行完整诊断（包含PCIe、显存、计算单元）
    log_info "运行 dcgmi diag -r 3（Level 3 完整诊断，最权威）..."
    save_raw "dcgmi_diag_full" bash -c "dcgmi diag -r 3 || true"

    # 健康状态
    save_raw "dcgmi_health" bash -c "dcgmi health -g all -c || true"

    # 各GPU详细统计（PCIe重放、ECC错误、Xid错误等）
    save_raw "dcgmi_stats" bash -c "dcgmi stats -g all -v || true"

    # 字段组枚举（支持的所有监控指标）
    save_raw "dcgmi_fieldgroups" bash -c "dcgmi discovery -l || true"

    log_ok "DCGM 完整诊断完成"
}

# =========================================
# 12. ECC 错误检查（数据中心GPU关键项）
# =========================================
test_ecc() {
    log_info "========== 12. ECC 错误检查 =========="

    # nvidia-smi 方式
    save_raw "nvidia_smi_ecc" \
        bash -c "nvidia-smi --query-gpu=index,name,ecc.mode.current,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total,retired_pages.single_bit_ecc.count,retired_pages.double_bit.count,retired_pages.pending --format=csv 2>/dev/null || echo 'ECC Query Unavailable'"

    # Xid 错误计数
    save_raw "nvidia_smi_retired_pages" \
        bash -c "nvidia-smi -q -d ECC,MEMORY,RETIRED_PAGES,PAGE_RETIREMENT 2>/dev/null || true"

    # dmesg 中的 Xid 错误
    save_raw "dmesg_xid" \
        bash -c "dmesg | grep -i 'NVRM\|Xid\|nvrm' | tail -100 2>/dev/null || true"

    log_ok "ECC/错误计数采集完成"
}

# =========================================
# 12.5 NVIDIA 原厂现场质检（Field Validation）
#   覆盖 NVIDIA 官方工厂/现场质检标准全量域：
#   ROW_REMAPPER(显存行重映射) / NVLink / MIG / TILE(多芯片封装)
#   POWER_MANAGEMENT / VIRTUALIZATION / SUPPORTED_CLOCKS
#   ENCODER/DECODER / SERIAL(保修验证) / COMPUTE(运行模式)
#   这是数据中心GPU(H100~B300)原厂质检/RMA判定的核心依据
# =========================================
test_factory_validation() {
    log_info "========== 12.5 NVIDIA 原厂现场质检（Field Validation） =========="

    # --- (1) 显存行重映射器 ROW_REMAPPER ---
    # NVIDIA 硬件级显存冗余修复机制：当某显存行故障时，硬件自动重映射到备用行。
    # 若备用行耗尽（remapping_failure=Yes / pending_remissions>0），则需RMA。
    # 这是原厂质检/RMA判定的【第一核心依据】
    log_info "[Field-01] 显存行重映射器（ROW_REMAPPER）..."
    save_raw "nvsmi_row_remapper" \
        bash -c "nvidia-smi -q -d ROW_REMAPPER 2>/dev/null || echo 'ROW_REMAPPER 不可用（驱动版本过低或消费级GPU）'"

    # --- (2) NVLink 状态与错误计数 ---
    # H100/B200/B300 多GPU服务器依赖NVLink/NVSwitch互联，链路错误=硬件故障
    log_info "[Field-02] NVLink 状态与错误计数..."
    save_raw "nvsmi_nvlink_status" bash -c "nvidia-smi nvlink -s 2>/dev/null || echo 'NVLink 不可用'"
    save_raw "nvsmi_nvlink_counters" bash -c "nvidia-smi nvlink -ct 0 2>/dev/null || true"  # 计数器类型0
    save_raw "nvsmi_nvlink_errors" bash -c "nvidia-smi nvlink -e 2>/dev/null || true"       # 错误计数
    # NVLink 拓扑和远端GPU信息
    save_raw "nvsmi_nvlink_topology" bash -c "nvidia-smi -q -d NVLINK 2>/dev/null || true"

    # NVSwitch 检测（DGX/HGX级服务器）
    save_raw "nvsmi_nvswitch" bash -c "nvidia-smi -q -d NVSWITCH 2>/dev/null || true"
    save_raw "lspci_nvswitch" bash -c "lspci 2>/dev/null | grep -i 'nvswitch\|ibm.*npu' || echo '未检测到NVSwitch'"

    # --- (3) MIG 多实例GPU验证 ---
    # H100/B200/B300 的关键特性：将单GPU切分为多个独立计算实例
    log_info "[Field-03] MIG 多实例GPU配置验证..."
    save_raw "nvsmi_mig_status" bash -c "nvidia-smi mig -lgi 2>/dev/null || echo 'MIG 未启用或不可用'"
    save_raw "nvsmi_mig_ci" bash -c "nvidia-smi mig -lci 2>/dev/null || true"
    save_raw "nvsmi_mig_device" bash -c "nvidia-smi -q -d MIG 2>/dev/null || true"

    # --- (4) TILE 多芯片封装验证 ---
    # B200/B300 采用多芯片封装(multi-die)，需验证各Tile状态
    log_info "[Field-04] TILE 多芯片封装状态验证..."
    save_raw "nvsmi_tile" bash -c "nvidia-smi -q -d TILE 2>/dev/null || echo 'TILE 不可用（单芯片GPU正常）'"

    # --- (5) 功耗管理策略验证 ---
    log_info "[Field-05] 功耗管理策略（POWER_MANAGEMENT）..."
    save_raw "nvsmi_power_mgmt" bash -c "nvidia-smi -q -d POWER_MANAGEMENT 2>/dev/null || echo 'POWER_MANAGEMENT 不可用'"

    # --- (6) 虚拟化支持验证（vGPU/SR-IOV）---
    log_info "[Field-06] 虚拟化支持验证（VIRTUALIZATION）..."
    save_raw "nvsmi_virtualization" bash -c "nvidia-smi -q -d VIRTUALIZATION 2>/dev/null || echo 'VIRTUALIZATION 不可用'"

    # --- (7) 合规时钟频率验证 ---
    # 确认GPU能运行在NVIDIA规格书标称的时钟频率
    log_info "[Field-07] 合规时钟频率（SUPPORTED_CLOCKS）..."
    save_raw "nvsmi_supported_clocks" bash -c "nvidia-smi -q -d SUPPORTED_CLOCKS 2>/dev/null || echo 'SUPPORTED_CLOCKS 不可用'"

    # --- (8) 视频编码/解码引擎验证（NVENC/NVDEC）---
    log_info "[Field-08] 视频编解码引擎（NVENC/NVDEC）..."
    save_raw "nvsmi_encoder" bash -c "nvidia-smi -q -d ENCODER 2>/dev/null || true"
    save_raw "nvsmi_decoder" bash -c "nvidia-smi -q -d DECODER 2>/dev/null || true"

    # --- (9) 序列号/保修验证 ---
    # 原厂质检需核对GPU序列号与发货记录一致，防伪/保修验证
    log_info "[Field-09] 序列号/保修验证（SERIAL）..."
    save_raw "nvsmi_serial" bash -c "nvidia-smi -q -d SERIAL 2>/dev/null || echo 'SERIAL 不可用'"
    # inforom 完整性（含OEM/inforom校验和）
    save_raw "nvsmi_inforom" bash -c "nvidia-smi -q -d INFOROM 2>/dev/null || true"

    # --- (10) 运行模式验证（Persistence/Compute Mode）---
    log_info "[Field-10] 运行模式验证（COMPUTE/PERSISTENCE）..."
    save_raw "nvsmi_compute_mode" bash -c "nvidia-smi -q -d COMPUTE 2>/dev/null || true"
    save_raw "nvsmi_persistence" \
        bash -c "nvidia-smi --query-gpu=index,persistence_mode,compute_mode,driver_version,vbios_version,inforom.img,inforom.oem,inforom.ece --format=csv 2>/dev/null || true"

    # --- (11) 全域一次性查询（备份完整快照，便于复核）---
    log_info "[Field-11] nvidia-smi 全域查询快照..."
    save_raw "nvsmi_all_domains" \
        bash -c "nvidia-smi -q 2>/dev/null || echo 'nvidia-smi -q 失败'"

    # --- (12) DCGM 策略合规与分组验证 ---
    if command -v dcgmi &>/dev/null; then
        log_info "[Field-12] DCGM 策略合规与GPU分组..."
        save_raw "dcgmi_policy" bash -c "dcgmi policy -l 2>/dev/null || true"  # 列出策略
        save_raw "dcgmi_group" bash -c "dcgmi group -l 2>/dev/null || true"  # 列出GPU分组
        save_raw "dcgmi_profile" bash -c "dcgmi profile -l 2>/dev/null || true"  # 性能配置文件
        save_raw "dcgmi_settings" bash -c "dcgmi settings -l 2>/dev/null || true"  # 全局设置
    fi

    # --- (13) 页面重映射/退役详细状态（补充ECC部分的深度信息）---
    log_info "[Field-13] 页面退役与重映射详细状态..."
    save_raw "nvsmi_page_retirement" bash -c "nvidia-smi -q -d PAGE_RETIREMENT,RETIRED_PAGES 2>/dev/null || true"

    # --- (14) CC（Concurrent Command）/可恢复页错误计数 ---
    save_raw "nvsmi_clock_policy" bash -c "nvidia-smi -q -d CLOCK_POLICY 2>/dev/null || true"

    log_ok "NVIDIA 原厂现场质检（Field Validation）全部完成"
}

# =========================================
# 13. 显存主动校验测试（cuda_memtest: 10种模式写入-读出-比对）
#   这是行业级显存质检标准，覆盖以下测试模式：
#   Test0: Walking 1s    Test1: Walking 0s   Test2: Random pattern
#   Test3: Gaussian     Test4: Solid Bits   Test5: Address Fetch
#   Test6: Block Seq     Test7: Checkerboard Test8: Shift
#   Test9: Inversions   Test10: Memory
#   任何模式报错 = 显存硬件故障 → 需RMA
# =========================================
test_memory() {
    log_info "========== 13. 显存主动校验测试（cuda_memtest 10种模式） =========="
    local factory_bin
    factory_bin=$(cat "${OUTPUT_DIR}/factory_bin_dir.txt" 2>/dev/null)
    local cuda_bin
    cuda_bin=$(cat "${OUTPUT_DIR}/cuda_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    local has_memtest=false
    if [ -x "${factory_bin}/cuda_memtest" ]; then
        has_memtest=true
    fi

    for (( i=0; i<gpu_count; i++ )); do
        if [ "${has_memtest}" = "true" ]; then
            log_info "GPU ${i}: 运行 cuda_memtest 10种模式显存校验（可能需要数分钟）..."
            CUDA_VISIBLE_DEVICES=${i} save_raw "cuda_memtest_gpu${i}" \
                "${factory_bin}/cuda_memtest" --disable_gpu_lock
        elif [ -x "${cuda_bin}/bandwidthTest" ]; then
            # 回退：bandwidthTest shmoo 模式（仅测带宽，不测正确性）
            log_warn "GPU ${i}: cuda_memtest 不可用，回退到 bandwidthTest shmoo（仅带宽测试，无正确性校验）"
            CUDA_VISIBLE_DEVICES=${i} save_raw "memtest_shmoo_gpu${i}" \
                "${cuda_bin}/bandwidthTest" --device=${i} --memory=device --mode=shmoo
        else
            log_warn "GPU ${i}: 无可用显存测试工具，跳过"
        fi
    done

    log_ok "显存主动校验测试完成"
}

# =========================================
# 13.5 满载烧机+正确性校验（gpu-burn: 矩阵乘法结果比对）
#   gpu-burn 对每块GPU持续运行大矩阵乘法，
#   计算结果与CPU参考值逐元素比对，任何不匹配=计算单元故障
#   这与dcgmi diag -r 3中的Targeted Stress互补，是出厂质检必跑项
# =========================================
test_gpu_burn() {
    log_info "========== 13.5 满载烧机+正确性校验（gpu-burn） =========="
    local factory_bin
    factory_bin=$(cat "${OUTPUT_DIR}/factory_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    if [ ! -x "${factory_bin}/gpu_burn" ]; then
        log_warn "gpu_burn 不可用，跳过正确性烧机测试"
        return
    fi

    # 启动后台温度/功耗监控
    log_info "启动 nvidia-smi 后台监控（gpu-burn 烧机期间）..."
    nvidia-smi --query-gpu=timestamp,index,name,temperature.gpu,power.draw,fan.speed,utilization.gpu,memory.used,memory.total \
        --format=csv -l 2 -f "${RAW_DATA_DIR}/gpu_monitor_burn.csv" &
    local monitor_pid=$!

    # gpu-burn 用法: gpu_burn <seconds> <device_id>
    # 逐GPU烧机（确保每块GPU都被独立校验）
    for (( i=0; i<gpu_count; i++ )); do
        local burn_time=120  # 每块GPU烧120秒，售后服务建议120~300秒
        log_info "GPU ${i}: gpu-burn 满载烧机 ${burn_time} 秒（含矩阵乘法正确性校验）..."
        CUDA_VISIBLE_DEVICES=${i} save_raw "gpu_burn_gpu${i}" \
            "${factory_bin}/gpu_burn" "${burn_time}" "${i}"
    done

    # 停止监控
    kill "${monitor_pid}" 2>/dev/null; wait "${monitor_pid}" 2>/dev/null

    log_ok "满载烧机+正确性校验完成"
}

# =========================================
# 14. PCIe 链路状态重训检查
# =========================================
test_pcie_link() {
    log_info "========== 14. PCIe 链路状态检查 =========="

    # 运行带宽测试前后对比链路状态
    save_raw "pcie_link_status" \
        nvidia-smi --query-gpu=index,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,pcie.link.gen.max,pcie.replay_errors --format=csv

    # lspci 详细链路信息
    save_raw "lspci_vga_verbose" \
        bash -c "for dev in \$(lspci | grep -i nvidia | awk '{print \$1}'); do echo '=== PCIe $dev ==='; lspci -vvv -s \$dev | grep -E 'LnkSta|LnkCap|DevSta|Width|Speed' ; done"

    log_ok "PCIe 链路状态采集完成"
}

# =========================================
# 15. 调用 Python 生成报告
# =========================================
generate_final_report() {
    log_info "========== 15. 生成售后服务报告 =========="

    if [ ! -f "${SCRIPT_DIR}/generate_report.py" ]; then
        log_error "找不到报告生成脚本 generate_report.py，请确认其与本脚本同目录"
        return 1
    fi

    python3 "${SCRIPT_DIR}/generate_report.py" \
        --output_dir "${OUTPUT_DIR}" \
        --raw_data_dir "${RAW_DATA_DIR}" \
        --log_file "${LOG_FILE}" \
        2>&1 | tee -a "${LOG_FILE}"

    if [ -f "${OUTPUT_DIR}/report.html" ]; then
        log_ok "售后报告已生成: ${OUTPUT_DIR}/report.html"
        log_ok "JSON数据已生成: ${OUTPUT_DIR}/report_data.json"
    fi
}

# =========================================
# 主流程
# =========================================
main() {
    # 参数解析
    local skip_install=false
    local stress_only=false
    for arg in "$@"; do
        case "${arg}" in
            --skip-install) skip_install=true ;;
            --stress-only)  stress_only=true  ;;
            -h|--help)
                cat <<EOF
NVIDIA GPU 售后服务自动化测试脚本

用法:
  sudo bash $0 [选项]

选项:
  --skip-install    跳过驱动/CUDA/DCGM安装，直接运行测试
  --stress-only     仅运行压力测试，快速查验温度/功耗
  -h, --help        显示此帮助

输出目录:
  ${SCRIPT_DIR}/gpu_test_results_YYYYMMDD_HHMMSS/
    ├── report.html              (售后服务正式报告，HTML格式)
    ├── report_data.json         (结构化原始数据)
    ├── test.log                 (完整运行日志)
    ├── cuda_samples_bin/        (编译后的官方测试工具)
    └── raw_data/                (所有原始测试输出)
EOF
                exit 0
                ;;
        esac
    done

    init
    log_info "输出目录: ${OUTPUT_DIR}"

    if [ "${stress_only}" = "true" ]; then
        install_system_deps
        check_system
        check_nvidia_driver
        enumerate_gpus
        install_cuda_toolkit
        test_stress_thermal
        generate_final_report
        exit 0
    fi

    if [ "${skip_install}" = "false" ]; then
        install_system_deps
        check_system
        check_nvidia_driver
        install_cuda_toolkit
        install_dcgm
        install_factory_tools   # 4.5 下载编译 gpu-burn + cuda_memtest
    else
        install_system_deps
        check_system
        check_nvidia_driver
        # 检查CUDA可用性
        export PATH="/usr/local/cuda/bin:${PATH}"
        export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"
        if command -v nvcc &>/dev/null; then
            compile_cuda_samples
        fi
        install_factory_tools
    fi

    # ============== 测试阶段 ==============
    enumerate_gpus            # 5. 门禁
    test_pcie_link            # 14. PCIe链路状态
    test_device_query         # 6. deviceQuery
    test_ecc                  # 12. ECC
    test_factory_validation   # 12.5 原厂现场质检（Field Validation）
    test_memory               # 13. 显存主动校验（cuda_memtest 10种模式）
    test_gpu_burn             # 13.5 满载烧机+正确性校验（gpu-burn）
    test_bandwidth            # 7. PCIe带宽
    test_p2p                  # 8. P2P
    test_cuda_perf            # 9. 计算性能
    test_stress_thermal       # 10. 温度功耗压力
    test_dcgm                 # 11. DCGM 完整诊断

    # ============== 生成报告 ==============
    generate_final_report   # 15.

    log_ok "========== 全部测试完成 =========="
    log_ok "报告目录: ${OUTPUT_DIR}"
    log_ok "请将 report.html 和 report_data.json 一并提交存档"
}

main "$@"
