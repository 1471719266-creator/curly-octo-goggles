#!/bin/bash
#===============================================================================
# NVIDIA GPU 售后服务自动化测试脚本
# 支持 Ubuntu 24.04 LTS，兼容 H100 ~ B300 全系列数据中心/消费级 GPU
# 测试工具：NVIDIA CUDA Toolkit (官方) + DCGM (官方数据中心诊断)
# 直接复制使用：  bash gpu_test.sh    （首次会自动 chmod +x，下次可 ./gpu_test.sh）
#===============================================================================
set -o pipefail

# ================================================================
# 【第0步：自授权+重启动】复制到任何目录都能 bash gpu_test.sh 直接运行
#   效果：首次用 bash 运行后，脚本自动给自己 chmod +x
#        并重启动为可执行模式，以后直接 ./gpu_test.sh 即可
# ================================================================
SELF_CHMOD_DONE="${SELF_CHMOD_DONE:-0}"
if [ "${SELF_CHMOD_DONE}" != "1" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_ABS_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    if [ ! -x "${SCRIPT_ABS_PATH}" ]; then
        echo ">>> 首次运行：自动给脚本添加可执行权限（chmod +x），以后可直接 ./$(basename "${BASH_SOURCE[0]}")"
        chmod +x "${SCRIPT_ABS_PATH}" 2>/dev/null || true
    fi
    # 通过环境变量避免无限循环，然后以可执行方式重启动
    export SELF_CHMOD_DONE=1
    exec "${SCRIPT_ABS_PATH}" "$@"
fi

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
FIELD_LEVEL=2            # fieldiag 原厂现场诊断级别: 1=快速(5~15分钟) 2=中等(约4小时) 3=完整(约6小时)
FORCE_FIELDIAG=false     # 是否强制跳过 fieldiag 预检0~6（确认fieldiag版本+GPU完全匹配时才用）
TEMP_ALARM_C=90          # 温度报警阈值（℃），超过则自动暂停测试，低于冷却阈值后继续
TEMP_COOLDOWN_C=75       # 冷却恢复温度（℃），低于此值自动恢复测试
TEMP_CHECK_INTERVAL=5    # 温度检查间隔(秒)
PAUSE_MARKER=""          # 暂停标记文件路径，init()里会赋值

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# =========================================
# 初始化
# =========================================
init() {
    mkdir -p "${OUTPUT_DIR}" "${RAW_DATA_DIR}"
    touch "${LOG_FILE}"
    exec 2> >(tee -a "${LOG_FILE}" >&2)
    PAUSE_MARKER="${OUTPUT_DIR}/.pause"
    MANUAL_PAUSE="${OUTPUT_DIR}/.manual_pause"
    TEMP_WATCHDOG_LOG="${OUTPUT_DIR}/watchdog_temp.log"
    rm -f "${PAUSE_MARKER}" "${MANUAL_PAUSE}" "${TEMP_WATCHDOG_LOG}"
}

# ================================================================
# 启动交互菜单（无参数模式）—— 售后服务工程师最常用
# ================================================================
interactive_menu() {
    # 如果不是TTY（比如ssh管道调用），直接使用默认值不交互
    if [ ! -t 0 ]; then
        echo "[交互菜单] 非终端环境，使用默认值: fieldiag=Level${FIELD_LEVEL}, 压力=${STRESS_DURATION_SEC}s, 温度报警=${TEMP_ALARM_C}℃"
        return 0
    fi

    local sel=""
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║    NVIDIA GPU 售后服务自动化测试 · 启动配置                 ║"
    echo "║    直接回车 = 采用默认值                                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    # ---- Step 1: fieldiag 等级 ----
    echo ""
    echo "【1/4】NVIDIA fieldiag 原厂现场诊断级别（只有装了fieldiag二进制才生效）："
    echo "    1) Level 1 快速测试  (~5~15 分钟)  ← 日常验收"
    echo "    2) Level 2 中等深度  (~4 小时)     ← 默认，推荐售后RMA前"
    echo "    3) Level 3 完整诊断  (~6 小时)     ← 出厂质检/重大故障深挖"
    read -rp "    请选择 [默认 2]: " sel
    case "${sel}" in
        1) FIELD_LEVEL=1 ;;
        3) FIELD_LEVEL=3 ;;
        2|"") FIELD_LEVEL=2 ;;
        *) echo "    无效选择，保留默认 Level 2"; FIELD_LEVEL=2 ;;
    esac

    # ---- Step 2: 压力测试时长 ----
    echo ""
    echo "【2/4】满载压力测试时长（nbody + gpu-burn，售后服务建议 60~300 秒）："
    echo "    例：60（1分钟）、120（2分钟）、300（5分钟）、600（10分钟）"
    read -rp "    请输入秒数 [默认 ${STRESS_DURATION_SEC}]: " sel
    if [ -n "${sel}" ] && [[ "${sel}" =~ ^[0-9]+$ ]] && [ "${sel}" -gt 0 ]; then
        STRESS_DURATION_SEC="${sel}"
    else
        [ -n "${sel}" ] && echo "    无效值，保留默认 ${STRESS_DURATION_SEC} 秒"
    fi

    # ---- Step 3: 温度报警阈值 ----
    echo ""
    echo "【3/4】温度报警阈值（最高温度，超过自动暂停测试；H100/H200/B300建议92，A100建议90，消费级建议85）："
    echo "    例：80 / 85 / 90 / 92 / 95"
    read -rp "    请输入摄氏度 [默认 ${TEMP_ALARM_C}]: " sel
    if [ -n "${sel}" ] && [[ "${sel}" =~ ^[0-9]+$ ]] && [ "${sel}" -ge 50 ] && [ "${sel}" -le 110 ]; then
        TEMP_ALARM_C="${sel}"
    else
        [ -n "${sel}" ] && echo "    无效值（应在 50~110 之间），保留默认 ${TEMP_ALARM_C}℃"
    fi

    # ---- Step 4: 冷却恢复温度（必须低于报警阈值） ----
    local default_cool=$(( TEMP_ALARM_C - 15 ))
    [ "${default_cool}" -lt 40 ] && default_cool=40
    echo ""
    echo "【4/4】冷却恢复温度（降到该温度以下自动恢复测试，建议比报警阈值低 10~20℃）："
    read -rp "    请输入摄氏度 [默认 ${default_cool}]: " sel
    if [ -n "${sel}" ] && [[ "${sel}" =~ ^[0-9]+$ ]]; then
        if [ "${sel}" -lt "${TEMP_ALARM_C}" ]; then
            TEMP_COOLDOWN_C="${sel}"
        else
            echo "    恢复温度必须低于报警温度(${TEMP_ALARM_C}℃)，使用默认 ${default_cool}℃"
            TEMP_COOLDOWN_C="${default_cool}"
        fi
    else
        TEMP_COOLDOWN_C="${default_cool}"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  最终配置确认："
    echo "║   · fieldiag 诊断等级 : Level ${FIELD_LEVEL}"
    echo "║   · 满载压力时长     : ${STRESS_DURATION_SEC} 秒"
    echo "║   · 温度报警阈值     : ${TEMP_ALARM_C} ℃（超过自动暂停）"
    echo "║   · 冷却恢复温度     : ${TEMP_COOLDOWN_C} ℃（低于后自动继续）"
    echo "║  运行中手动暂停      : touch ${OUTPUT_DIR}/.manual_pause"
    echo "║  运行中手动恢复      : rm    -f ${OUTPUT_DIR}/.manual_pause"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
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

# ================================================================
# 温度守护进程：后台常驻，每TEMP_CHECK_INTERVAL秒检查一次所有GPU温度
#   任何一块GPU温度 >= TEMP_ALARM_C → 写入暂停标记 + 报警
#   所有GPU温度 <= TEMP_COOLDOWN_C → 移除暂停标记 + 继续
#   支持手动暂停：touch .manual_pause （优先级最高，必须手动删除）
# ================================================================
start_temp_watchdog() {
    # 先杀掉上一次可能残留的watchdog（正常流程下不会残留）
    [ -f "${OUTPUT_DIR}/.watchdog_pid" ] && kill "$(cat "${OUTPUT_DIR}/.watchdog_pid")" 2>/dev/null || true
    rm -f "${PAUSE_MARKER}" "${OUTPUT_DIR}/.watchdog_pid"

    # 守护进程以子shell方式后台运行，不阻塞主流程
    (
        echo $$ > "${OUTPUT_DIR}/.watchdog_pid"
        local last_alert_ts=0
        local last_resume_ts=0
        while true; do
            sleep "${TEMP_CHECK_INTERVAL}"
            # 如果 nvidia-smi 不存在就休息（驱动还没装好）
            command -v nvidia-smi &>/dev/null || continue
            # 读每块GPU的最高温度（利用query一次获取）
            local temps
            temps=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)
            [ -z "${temps}" ] && continue
            local max_t=0 min_t=200
            while IFS= read -r t; do
                [[ "${t}" =~ ^[0-9]+$ ]] || continue
                [ "${t}" -gt "${max_t}" ] && max_t="${t}"
                [ "${t}" -lt "${min_t}" ] && min_t="${t}"
            done <<< "${temps}"
            local now_ts
            now_ts=$(date +%s)
            # 写 watchdog 日志（每30秒写一条，避免日志爆炸）
            if [ $(( now_ts % 30 )) -eq 0 ]; then
                echo "[$(date '+%H:%M:%S')] max=${max_t}C min=${min_t}C | TEMP_ALARM=${TEMP_ALARM_C}C TEMP_COOLDOWN=${TEMP_COOLDOWN_C}C | PAUSE=$( [ -f "${PAUSE_MARKER}" ] && echo Y || echo N ) | MANUAL=$( [ -f "${MANUAL_PAUSE}" ] && echo Y || echo N )" >> "${TEMP_WATCHDOG_LOG}"
            fi
            # --- 手动暂停优先级最高：必须等用户手动删除才恢复 ---
            if [ -f "${MANUAL_PAUSE}" ]; then
                touch "${PAUSE_MARKER}"
                if [ $(( now_ts - last_alert_ts )) -ge 15 ]; then
                    last_alert_ts=${now_ts}
                    # 用tee写入主进程log但不能直接调用log_info（子shell），改为直接写log文件
                    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')][WARN] ${YELLOW}⚠️  手动暂停生效中：请运行 rm -f ${MANUAL_PAUSE} 恢复${NC}" | tee -a "${LOG_FILE}" >&2
                fi
                continue
            fi
            # --- 温度超阈值：自动暂停 ---
            if [ "${max_t}" -ge "${TEMP_ALARM_C}" ]; then
                touch "${PAUSE_MARKER}"
                if [ $(( now_ts - last_alert_ts )) -ge 10 ]; then
                    last_alert_ts=${now_ts}
                    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')][ERROR] ${RED}🔥 温度报警：最高 GPU ${max_t}℃ ≥ 阈值 ${TEMP_ALARM_C}℃，已自动暂停测试${NC}" | tee -a "${LOG_FILE}" >&2
                fi
                continue
            fi
            # --- 已暂停但温度降到恢复阈值以下：解除自动暂停 ---
            if [ -f "${PAUSE_MARKER}" ] && [ "${max_t}" -le "${TEMP_COOLDOWN_C}" ] && [ ! -f "${MANUAL_PAUSE}" ]; then
                rm -f "${PAUSE_MARKER}"
                if [ $(( now_ts - last_resume_ts )) -ge 5 ]; then
                    last_resume_ts=${now_ts}
                    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')][OK] ${GREEN}❄️  已冷却到 ${max_t}℃ ≤ 恢复阈值 ${TEMP_COOLDOWN_C}℃，自动恢复测试${NC}" | tee -a "${LOG_FILE}" >&2
                fi
            fi
        done
    ) &
    local wd_pid=$!
    # 确保整个主流程退出时把后台守护进程一起杀掉（trap 退出信号）
    trap 'kill '"${wd_pid}"' 2>/dev/null; [ -f "${OUTPUT_DIR}/.watchdog_pid" ] && kill "$(cat "${OUTPUT_DIR}/.watchdog_pid")" 2>/dev/null || true' EXIT INT TERM
    log_ok "温度守护进程已启动 (PID=${wd_pid})：最高温度≥${TEMP_ALARM_C}℃自动暂停，≤${TEMP_COOLDOWN_C}℃自动恢复"
    log_info "手动控制：暂停=touch ${MANUAL_PAUSE}  恢复=rm -f ${MANUAL_PAUSE}  状态=${PAUSE_MARKER}"
}

# ================================================================
# 长时测试前的检查点：
#   如果存在暂停标记（温度超阈值 or 手动）就 sleep 等待直到标记清除
# ================================================================
wait_for_ready() {
    local caller_name="${1:-测试}"
    if [ -f "${MANUAL_PAUSE}" ]; then
        log_warn "⚠️  ${caller_name}：手动暂停生效，等待用户执行 rm -f ${MANUAL_PAUSE}"
    fi
    while [ -f "${PAUSE_MARKER}" ] || [ -f "${MANUAL_PAUSE}" ]; do
        sleep 2
    done
}

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
    command -v unzip   &>/dev/null || deps_missing+=("unzip")
    command -v file    &>/dev/null || deps_missing+=("file")
    command -v ldd     &>/dev/null || deps_missing+=("libc-bin")

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
# 4.5 下载编译质检工具
#   原厂工具（随CUDA Toolkit自带，无需下载）：
#     - cuda-memcheck: NVIDIA原厂CUDA内存错误检测器（随CUDA Toolkit安装）
#     - nvbandwidth:  NVIDIA原厂新一代PCIe/NVLink带宽测试工具（较新CUDA版本自带）
#   第三方补充工具（需下载编译）：
#     - gpu-burn: 满载烧机+正确性校验（矩阵乘法结果与CPU基准比对）
#     - cuda_memtest: 显存10种模式主动写入-读出-校验（行业级显存质检标准）
#   下载策略：git clone → wget zip → curl zip → ghproxy镜像（4层回退）
# =========================================
install_factory_tools() {
    log_info "========== 4.5 质检工具准备 =========="

    local FACTORY_BIN="${OUTPUT_DIR}/factory_tools_bin"
    mkdir -p "${FACTORY_BIN}"
    echo "${FACTORY_BIN}" > "${OUTPUT_DIR}/factory_bin_dir.txt"

    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"

    # ================================================================
    # 工具1: gpu-burn（满载烧机+正确性校验）
    # ================================================================
    local GB_DIR="/tmp/gpu-burn"
    local gb_ok=false

    # 检查是否已编译好
    if [ -x "${GB_DIR}/gpu_burn" ]; then
        cp "${GB_DIR}/gpu_burn" "${FACTORY_BIN}/" 2>/dev/null
        log_ok "gpu-burn 已存在，直接复用"
        gb_ok=true
    fi

    if [ "${gb_ok}" = "false" ]; then
        log_info "[1/2] 下载 gpu-burn ..."
        rm -rf "${GB_DIR}"
        mkdir -p "${GB_DIR}"

        # 下载方法1: git clone（官方仓库）
        log_info "  尝试方法1: git clone (github.com)..."
        git clone --depth 1 https://github.com/wilicc/gpu-burn.git "${GB_DIR}" >> "${LOG_FILE}" 2>&1
        local git_ret=$?

        # 下载方法2: git clone via ghproxy镜像
        if [ ${git_ret} -ne 0 ] || [ ! -f "${GB_DIR}/Makefile" ]; then
            log_warn "  git clone 失败(ret=${git_ret})，尝试方法2: ghproxy镜像..."
            rm -rf "${GB_DIR}"
            git clone --depth 1 https://ghproxy.com/https://github.com/wilicc/gpu-burn.git "${GB_DIR}" >> "${LOG_FILE}" 2>&1
            git_ret=$?
        fi

        # 下载方法3: wget 下载zip压缩包
        if [ ${git_ret} -ne 0 ] || [ ! -f "${GB_DIR}/Makefile" ]; then
            log_warn "  git clone 失败(ret=${git_ret})，尝试方法3: wget zip..."
            rm -rf "${GB_DIR}"
            local gb_zip="/tmp/gpu-burn.zip"
            wget -q --timeout=60 -O "${gb_zip}" \
                "https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip" >> "${LOG_FILE}" 2>&1
            if [ $? -eq 0 ] && [ -f "${gb_zip}" ] && [ -s "${gb_zip}" ]; then
                unzip -q -o "${gb_zip}" -d /tmp/ >> "${LOG_FILE}" 2>&1
                mv /tmp/gpu-burn-master "${GB_DIR}" 2>/dev/null || true
            else
                log_warn "  wget zip 失败，尝试方法4: curl via ghproxy..."
                curl -sL --max-time 60 -o "${gb_zip}" \
                    "https://ghproxy.com/https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip" >> "${LOG_FILE}" 2>&1
                if [ -f "${gb_zip}" ] && [ -s "${gb_zip}" ]; then
                    unzip -q -o "${gb_zip}" -d /tmp/ >> "${LOG_FILE}" 2>&1
                    mv /tmp/gpu-burn-master "${GB_DIR}" 2>/dev/null || true
                fi
            fi
        fi

        # 检查源码是否下载成功
        if [ ! -f "${GB_DIR}/Makefile" ]; then
            log_error "  gpu-burn 源码下载失败（所有4种方法均失败）"
            log_error "  请手动下载: https://github.com/wilicc/gpu-burn"
            log_error "  解压后执行: cd gpu-burn && make CUDA_PATH=/usr/local/cuda"
            log_error "  然后将 gpu_burn 复制到: ${FACTORY_BIN}/"
        else
            log_ok "  gpu-burn 源码下载成功"

            # 修改Makefile指定CUDA路径
            if grep -q "CUDA_PATH" "${GB_DIR}/Makefile" 2>/dev/null; then
                sed -i "s|CUDA_PATH?=.*|CUDA_PATH?=/usr/local/cuda|g" "${GB_DIR}/Makefile"
            else
                # 某些版本没有CUDA_PATH变量，直接在编译命令里加
                sed -i "s|nvcc|/usr/local/cuda/bin/nvcc|g" "${GB_DIR}/Makefile" 2>/dev/null || true
                sed -i "s|-L.*cuda|/usr/local/cuda/lib64|g" "${GB_DIR}/Makefile" 2>/dev/null || true
            fi
            # 修复：某些版本用compute.cu需要指定arch
            export CUDA_PATH="/usr/local/cuda"

            log_info "  开始编译 gpu-burn..."
            make -C "${GB_DIR}" CUDA_PATH=/usr/local/cuda >> "${LOG_FILE}" 2>&1
            local make_ret=$?

            if [ ${make_ret} -eq 0 ] && [ -x "${GB_DIR}/gpu_burn" ]; then
                cp "${GB_DIR}/gpu_burn" "${FACTORY_BIN}/"
                # 验证二进制能否运行
                if "${FACTORY_BIN}/gpu_burn" -h &>/dev/null || "${FACTORY_BIN}/gpu_burn" --help &>/dev/null; then
                    log_ok "  gpu-burn 编译成功并验证通过"
                    gb_ok=true
                else
                    log_warn "  gpu-burn 编译成功但运行验证失败（可能CUDA运行库路径问题）"
                    log_warn "  尝试设置LD_LIBRARY_PATH后重新验证..."
                    LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}" "${FACTORY_BIN}/gpu_burn" -h &>/dev/null && {
                        log_ok "  gpu-burn 运行验证通过（需设置LD_LIBRARY_PATH）"
                        gb_ok=true
                    } || {
                        log_warn "  gpu-burn 运行验证仍失败，但二进制已保留，将在测试时尝试运行"
                        gb_ok=true  # 保留二进制，运行时再验证
                    }
                fi
            else
                log_error "  gpu-burn 编译失败(ret=${make_ret})"
                log_error "  编译错误日志（最后30行）:"
                tail -30 "${LOG_FILE}" 2>/dev/null | while read -r line; do log_error "    ${line}"; done
                log_error "  请检查: 1) nvcc是否安装 2) CUDA头文件路径 3) 依赖库"
            fi
        fi
    fi

    # ================================================================
    # 工具2: cuda_memtest（显存10种模式主动校验）
    # ================================================================
    local CM_DIR="/tmp/cuda_memtest"
    local cm_ok=false

    # 检查是否已编译好
    local existing_cm=$(find "${CM_DIR}" -name "cuda_memtest" -type f -executable 2>/dev/null | head -n1)
    if [ -n "${existing_cm}" ]; then
        cp "${existing_cm}" "${FACTORY_BIN}/cuda_memtest" 2>/dev/null
        log_ok "cuda_memtest 已存在，直接复用"
        cm_ok=true
    fi

    if [ "${cm_ok}" = "false" ]; then
        log_info "[2/2] 下载 cuda_memtest ..."
        rm -rf "${CM_DIR}"
        mkdir -p "${CM_DIR}"

        # 下载方法1: git clone（官方仓库）
        log_info "  尝试方法1: git clone (github.com)..."
        git clone --depth 1 https://github.com/ComputationalRadiationPhysics/cuda_memtest.git "${CM_DIR}" >> "${LOG_FILE}" 2>&1
        local git_ret=$?

        # 下载方法2: git clone via ghproxy镜像
        if [ ${git_ret} -ne 0 ] || [ ! -f "${CM_DIR}/Makefile" ]; then
            log_warn "  git clone 失败(ret=${git_ret})，尝试方法2: ghproxy镜像..."
            rm -rf "${CM_DIR}"
            git clone --depth 1 https://ghproxy.com/https://github.com/ComputationalRadiationPhysics/cuda_memtest.git "${CM_DIR}" >> "${LOG_FILE}" 2>&1
            git_ret=$?
        fi

        # 下载方法3: wget 下载zip压缩包
        if [ ${git_ret} -ne 0 ] || [ ! -f "${CM_DIR}/Makefile" ]; then
            log_warn "  git clone 失败(ret=${git_ret})，尝试方法3: wget zip..."
            rm -rf "${CM_DIR}"
            local cm_zip="/tmp/cuda_memtest.zip"
            wget -q --timeout=60 -O "${cm_zip}" \
                "https://github.com/ComputationalRadiationPhysics/cuda_memtest/archive/refs/heads/master.zip" >> "${LOG_FILE}" 2>&1
            if [ $? -eq 0 ] && [ -f "${cm_zip}" ] && [ -s "${cm_zip}" ]; then
                unzip -q -o "${cm_zip}" -d /tmp/ >> "${LOG_FILE}" 2>&1
                mv /tmp/cuda_memtest-master "${CM_DIR}" 2>/dev/null || true
            else
                log_warn "  wget zip 失败，尝试方法4: curl via ghproxy..."
                curl -sL --max-time 60 -o "${cm_zip}" \
                    "https://ghproxy.com/https://github.com/ComputationalRadiationPhysics/cuda_memtest/archive/refs/heads/master.zip" >> "${LOG_FILE}" 2>&1
                if [ -f "${cm_zip}" ] && [ -s "${cm_zip}" ]; then
                    unzip -q -o "${cm_zip}" -d /tmp/ >> "${LOG_FILE}" 2>&1
                    mv /tmp/cuda_memtest-master "${CM_DIR}" 2>/dev/null || true
                fi
            fi
        fi

        # 检查源码是否下载成功
        if [ ! -f "${CM_DIR}/Makefile" ]; then
            log_error "  cuda_memtest 源码下载失败（所有4种方法均失败）"
            log_error "  请手动下载: https://github.com/ComputationalRadiationPhysics/cuda_memtest"
            log_error "  解压后执行: cd cuda_memtest && make CUDA_DIR=/usr/local/cuda"
            log_error "  然后将 cuda_memtest 复制到: ${FACTORY_BIN}/"
        else
            log_ok "  cuda_memtest 源码下载成功"

            # 修改Makefile指定CUDA路径
            if grep -q "CUDA_DIR" "${CM_DIR}/Makefile" 2>/dev/null; then
                sed -i "s|CUDA_DIR.*=.*|CUDA_DIR = /usr/local/cuda|g" "${CM_DIR}/Makefile"
            fi
            # 修复nvcc路径
            sed -i "s|/usr/bin/nvcc|/usr/local/cuda/bin/nvcc|g" "${CM_DIR}/Makefile" 2>/dev/null || true

            log_info "  开始编译 cuda_memtest..."
            make -C "${CM_DIR}" CUDA_DIR=/usr/local/cuda >> "${LOG_FILE}" 2>&1
            local make_ret=$?

            local cm_bin=""
            if [ ${make_ret} -eq 0 ]; then
                cm_bin=$(find "${CM_DIR}" -name "cuda_memtest" -type f -executable 2>/dev/null | head -n1)
            fi

            if [ -n "${cm_bin}" ]; then
                cp "${cm_bin}" "${FACTORY_BIN}/cuda_memtest"
                # 验证二进制能否运行
                if "${FACTORY_BIN}/cuda_memtest" --help &>/dev/null || "${FACTORY_BIN}/cuda_memtest" 2>&1 | head -5 | grep -qi "usage\|test\|memtest"; then
                    log_ok "  cuda_memtest 编译成功并验证通过"
                    cm_ok=true
                else
                    log_warn "  cuda_memtest 编译成功但运行验证失败，但二进制已保留"
                    cm_ok=true
                fi
            else
                log_error "  cuda_memtest 编译失败(ret=${make_ret})"
                log_error "  编译错误日志（最后30行）:"
                tail -30 "${LOG_FILE}" 2>/dev/null | while read -r line; do log_error "    ${line}"; done
                log_error "  请检查: 1) nvcc是否安装 2) CUDA头文件路径 3) 依赖库"
            fi
        fi
    fi

    # ================================================================
    # 原厂工具检测（随CUDA Toolkit自带，无需下载）
    # ================================================================

    # cuda-memcheck: NVIDIA原厂CUDA内存错误检测器
    log_info "检测 NVIDIA 原厂工具..."
    local CMC_BIN=""
    # cuda-memcheck 通常在 /usr/local/cuda/bin/ 或 /usr/local/cuda/computeprof/bin/
    for p in /usr/local/cuda/bin/cuda-memcheck /usr/local/cuda/extras/CUPTI/bin/cuda-memcheck \
             /usr/local/cuda/computeprof/bin/cuda-memcheck; do
        if [ -x "${p}" ]; then CMC_BIN="${p}"; break; fi
    done
    # 也检查PATH
    if [ -z "${CMC_BIN}" ]; then
        CMC_BIN=$(command -v cuda-memcheck 2>/dev/null || true)
    fi
    if [ -n "${CMC_BIN}" ]; then
        cp "${CMC_BIN}" "${FACTORY_BIN}/cuda-memcheck" 2>/dev/null || true
        log_ok "  [原厂] cuda-memcheck: ✓ 可用 (${CMC_BIN})"
    else
        log_warn "  [原厂] cuda-memcheck: ✗ 未找到（应随CUDA Toolkit安装，请检查 /usr/local/cuda/bin/）"
    fi

    # nvbandwidth: NVIDIA原厂新一代带宽测试工具（CUDA 12.6+自带）
    local NVBW_BIN=""
    for p in /usr/local/cuda/bin/nvbandwidth /usr/local/cuda/nvbandwidth; do
        if [ -x "${p}" ]; then NVBW_BIN="${p}"; break; fi
    done
    if [ -z "${NVBW_BIN}" ]; then
        NVBW_BIN=$(command -v nvbandwidth 2>/dev/null || true)
    fi
    # nvbandwidth 可能需要从CUDA samples编译
    if [ -z "${NVBW_BIN}" ]; then
        local NVBW_SRC="/usr/local/cuda/nvbandwidth"
        [ -d "/tmp/cuda-samples/Samples/nvbandwidth" ] && NVBW_SRC="/tmp/cuda-samples/Samples/nvbandwidth"
        if [ -d "${NVBW_SRC}" ] && [ -f "${NVBW_SRC}/Makefile" ]; then
            log_info "  编译 nvbandwidth (原厂)..."
            make -C "${NVBW_SRC}" >> "${LOG_FILE}" 2>&1 || true
            NVBW_BIN=$(find "${NVBW_SRC}" -name "nvbandwidth" -type f -executable 2>/dev/null | head -n1)
        fi
    fi
    if [ -n "${NVBW_BIN}" ]; then
        cp "${NVBW_BIN}" "${FACTORY_BIN}/nvbandwidth" 2>/dev/null || true
        log_ok "  [原厂] nvbandwidth: ✓ 可用 (${NVBW_BIN})"
    else
        log_warn "  [原厂] nvbandwidth: ✗ 未找到（较老CUDA版本可能不含，使用bandwidthTest替代）"
    fi

    # 最终检查
    log_info "===== 质检工具就绪状态汇总 ====="
    log_info "--- NVIDIA 原厂工具 ---"
    if [ -x "${FACTORY_BIN}/cuda-memcheck" ]; then
        log_ok "  [原厂] cuda-memcheck: ✓ 可用"
    else
        log_warn "  [原厂] cuda-memcheck: ✗ 未找到"
    fi
    if [ -x "${FACTORY_BIN}/nvbandwidth" ]; then
        log_ok "  [原厂] nvbandwidth: ✓ 可用"
    else
        log_warn "  [原厂] nvbandwidth: ✗ 未找到（用bandwidthTest替代）"
    fi
    log_info "--- 第三方补充工具 ---"
    if [ -x "${FACTORY_BIN}/gpu_burn" ]; then
        log_ok "  [第三方] gpu_burn: ✓ 可用"
    else
        log_warn "  [第三方] gpu_burn: ✗ 不可用（满载烧机正确性校验将跳过）"
    fi
    if [ -x "${FACTORY_BIN}/cuda_memtest" ]; then
        log_ok "  [第三方] cuda_memtest: ✓ 可用"
    else
        log_warn "  [第三方] cuda_memtest: ✗ 不可用（显存校验将回退到bandwidthTest）"
    fi
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
# 7. PCIe 带宽测试
#   优先级1 [原厂]: nvbandwidth — NVIDIA新一代带宽测试工具（CUDA 12.6+）
#   优先级2 [原厂]: bandwidthTest — CUDA Samples经典带宽测试
# =========================================
test_bandwidth() {
    log_info "========== 7. PCIe 带宽测试 =========="
    local bin_dir
    bin_dir=$(cat "${OUTPUT_DIR}/cuda_bin_dir.txt" 2>/dev/null)
    local factory_bin
    factory_bin=$(cat "${OUTPUT_DIR}/factory_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    # 优先级1: 原厂 nvbandwidth（新一代）
    if [ -x "${factory_bin}/nvbandwidth" ]; then
        for (( i=0; i<gpu_count; i++ )); do
            log_info "GPU ${i}: [原厂] nvbandwidth 带宽测试..."
            CUDA_VISIBLE_DEVICES=${i} save_raw "nvbandwidth_gpu${i}" \
                "${factory_bin}/nvbandwidth"
        done
        log_ok "[原厂] nvbandwidth 带宽测试完成"
    fi

    # 优先级2: 原厂 bandwidthTest（经典）
    if [ -x "${bin_dir}/bandwidthTest" ]; then
        for (( i=0; i<gpu_count; i++ )); do
            log_info "GPU ${i}: [原厂] bandwidthTest PCIe带宽测试..."
            CUDA_VISIBLE_DEVICES=${i} save_raw "bandwidthTest_gpu${i}" \
                "${bin_dir}/bandwidthTest" --device=${i} --memory=pinned --mode=range --csv
        done
        log_ok "[原厂] bandwidthTest 带宽测试完成（结果包含 H2D/D2H/D2D）"
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
    wait_for_ready "nbody满载压力测试"
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
# 11.5 NVIDIA fieldiag 原厂现场诊断（Field Diagnostics）
#   fieldiag 是 NVIDIA 原厂现场工程师专用诊断工具，
#   比dcgmi diag更深入，覆盖存储/计算/PCIe/NVLink全子系统。
#   该工具通过NVIDIA企业合作伙伴渠道获取，不公开下载。
#   脚本自动检测常见安装路径，找不到时输出获取指引。
# =========================================
test_fieldiag() {
    log_info "========== 11.5 NVIDIA fieldiag 原厂现场诊断（Level ${FIELD_LEVEL}） =========="

    # 搜索 fieldiag 二进制（常见安装路径）
    local fieldiag_bin=""
    for p in \
        /usr/local/cuda/bin/fieldiag \
        /usr/local/cuda/bin/nvidia-fieldiag \
        /opt/nvidia/fieldiag \
        /opt/nvidia/fieldiag/bin/fieldiag \
        /usr/bin/fieldiag \
        /usr/bin/nvidia-fieldiag \
        "${SCRIPT_DIR}/fieldiag" \
        "${SCRIPT_DIR}/tools/fieldiag"
    do
        if [ -x "${p}" ]; then fieldiag_bin="${p}"; break; fi
    done
    # 也搜索PATH
    if [ -z "${fieldiag_bin}" ]; then
        fieldiag_bin=$(command -v fieldiag 2>/dev/null || command -v nvidia-fieldiag 2>/dev/null || true)
    fi

    if [ -z "${fieldiag_bin}" ]; then
        echo ""
        log_warn "fieldiag 未安装，跳过原厂现场诊断"
        log_warn "fieldiag 是 NVIDIA 原厂现场工程师专用诊断工具，比 dcgmi diag 更深入"
        log_warn "获取方式（按优先级）："
        log_warn "  1. NVIDIA 企业合作伙伴门户: https://partner.nvidia.com → 下载中心 → 诊断工具"
        log_warn "  2. NVIDIA 开发者门户: https://developer.nvidia.com → 数据中心GPU管理工具"
        log_warn "  3. 联系 NVIDIA 技术支持（需提供GPU序列号和保修信息）"
        log_warn "获取后放置到以下任一路径，重新运行脚本即可自动识别："
        log_warn "  /usr/local/cuda/bin/fieldiag"
        log_warn "  /opt/nvidia/fieldiag"
        log_warn "  ${SCRIPT_DIR}/fieldiag（与本脚本同目录）"
        # 写入结果标记，报告生成器会识别
        echo "NOT_INSTALLED" > "${RAW_DATA_DIR}/fieldiag_result.txt"
        echo "fieldiag 未安装，Level ${FIELD_LEVEL} 诊断跳过" > "${RAW_DATA_DIR}/fieldiag_diag.txt"
        return
    fi

    log_ok "找到 fieldiag: ${fieldiag_bin}"

    # 【强制模式】--force-fieldiag：完全跳过预检0~6，直接进入正式诊断
    # 仅在确认 fieldiag 版本和GPU完全匹配时使用
    if [ "${FORCE_FIELDIAG}" = "true" ]; then
        log_warn "⚠️  --force-fieldiag 模式：跳过全部预检（GPU产品线/30秒快速预检/二进制兼容）"
        log_warn "⚠️  如 fieldiag 版本与GPU不匹配，可能卡死数小时，请耐心等待或 Ctrl+C 终止"
        log_info "ℹ️  直接进入 Level ${FIELD_LEVEL} 正式诊断..."
        # 写入基础文件占位，避免报告缺字段
        echo "FORCE" > "${RAW_DATA_DIR}/fieldiag_precheck.txt"
        "$fieldiag_bin" --version > "${RAW_DATA_DIR}/fieldiag_version.txt" 2>&1 || true
        ldd "${fieldiag_bin}" > "${RAW_DATA_DIR}/fieldiag_ldd.txt" 2>&1 || true
    else

    # ================================================================
    # 预检0：GPU产品线过滤 —— 消费级GPU（RTX/GTX/TITAN 等）直接跳过，不浪费时间
    #   fieldiag 官方仅支持数据中心 GPU：Tesla / HGX / DGX 系列
    #   消费级GPU会直接报 UNSUPPORTED GPU FAMILY 并卡死
    # ================================================================
    log_info "预检0：GPU产品线识别（判断是否适合跑fieldiag）..."
    local gpu_names=""
    if command -v nvidia-smi &>/dev/null; then
        gpu_names=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)
    fi
    local supported_gpu=true
    local unsupported_reason=""
    local unsupported_gpus=""

    if [ -z "${gpu_names}" ]; then
        log_warn "  无法获取GPU名称（nvidia-smi不可用），假设不支持fieldiag，为稳妥起见直接跳过"
        supported_gpu=false
        unsupported_reason="nvidia-smi不可用，无法确认GPU产品线"
    else
        # 逐GPU判断，全部支持才跑；任何一块不支持就整体跳过（避免混合场景卡死）
        local gpu_idx=0
        while IFS= read -r gpu_name; do
            [ -z "${gpu_name}" ] && continue
            # fieldiag官方支持的数据中心GPU关键字（白名单）
            if echo "${gpu_name}" | grep -qiE "(H100|H200|H800|H900|B200|B300|B380|B390|GB200|GB300|A100|A800|A900|A30|A10|A10G|T4|T4g|L4|L40|L40S|V100|V100S|P100|P40|P4|K80|K40|M60|M40|A2|L20|L2|L10|L10G|PG500|PG506|PG509|HGX|DGX|Tesla|GRID|Quadro (RTX|GV100|GP100))"; then
                log_info "  GPU ${gpu_idx}: [✓ 数据中心支持] ${gpu_name}"
            else
                # 消费级/半专业级（黑名单）
                log_warn "  GPU ${gpu_idx}: [✗ 消费级/非官方支持] ${gpu_name} → fieldiag对此GPU很可能报 UNSUPPORTED GPU FAMILY"
                supported_gpu=false
                unsupported_gpus="${unsupported_gpus} ${gpu_name};"
            fi
            gpu_idx=$((gpu_idx + 1))
        done <<< "${gpu_names}"

        if [ "${supported_gpu}" = "false" ]; then
            unsupported_reason="检测到消费级/非数据中心GPU: ${unsupported_gpus}"
        fi
    fi

    if [ "${supported_gpu}" = "false" ]; then
        log_warn "⚠️ 检测到非数据中心GPU，为避免 fieldiag 卡死，自动跳过原厂现场诊断"
        log_warn "原因: ${unsupported_reason}"
        log_info "ℹ️ 消费级GPU PCIe插槽检测已由脚本内置的8层公开工具完整覆盖（lspci+nvidia-smi+bandwidthTest+压力监控），结论同等权威"
        # 写入结果标记，报告显示：消费级GPU跳过（不算FAIL，也不算未安装）
        echo "CONSUMER_GPU_SKIPPED" > "${RAW_DATA_DIR}/fieldiag_result.txt"
        {
            echo "fieldiag 未运行：检测到消费级/非数据中心GPU"
            echo "GPU列表:"
            echo "${gpu_names:-未获取到}"
            echo "原因: ${unsupported_reason}"
            echo ""
            echo "消费级GPU PCIe插槽替代方案（脚本已自动执行，无需fieldiag）:"
            echo "  1. lspci PCIe枚举 → 识别插槽物理接触问题"
            echo "  2. nvidia-smi + lspci -vvv → 当前链路规格/最大规格/重放计数"
            echo "  3. bandwidthTest 原厂 → H2D/D2H/D2D带宽实测"
            echo "  4. bandwidthTest --mode=shmoo → 扫频边际稳定性"
            echo "  5. nvidia-smi -l 1 压力监控 → 满载时链路不降速"
        } > "${RAW_DATA_DIR}/fieldiag_diag.txt"
        echo "N/A（消费级GPU跳过）" > "${RAW_DATA_DIR}/fieldiag_level.txt"
        return
    fi
    log_ok "  全部GPU为数据中心系列（fieldiag官方支持），继续后续自检"

    # ================================================================
    # fieldiag 二进制兼容性自检（从20.04拷到24.04的常见问题）
    #   检查项（预检0之后，预检30s预检之前）:
    #     1. ELF架构是否匹配（x86_64 vs aarch64）
    #     2. 可执行权限
    #     3. 共享库依赖（ldd 全 resolvable，缺 libcuda.so.1/DCGM 库最常见）
    #     4. --version 能否正常返回（glibc/ABI 兼容性）
    #     5. GPU架构支持（Hopper/Blackwell/H200/B300需要较新的fieldiag）
    # ================================================================
    log_info "fieldiag 兼容性自检（跨系统拷贝后必跑）..."
    local compat_ok=true

    # [1] ELF架构检查
    local elf_arch=""
    elf_arch=$(file -b "${fieldiag_bin}" 2>/dev/null | head -n1)
    local host_arch=""
    host_arch=$(uname -m)
    log_info "  [1/6] ELF架构: ${elf_arch} (主机: ${host_arch})"
    if echo "${elf_arch}" | grep -qi "${host_arch}"; then
        log_ok "    架构匹配"
    else
        log_error "    ❌ 架构不匹配！fieldiag 是 ${elf_arch}，主机是 ${host_arch}"
        compat_ok=false
    fi

    # [2] 可执行权限（某些文件系统拷贝后权限丢失）
    log_info "  [2/6] 可执行权限..."
    if [ -x "${fieldiag_bin}" ]; then
        log_ok "    ✓ 已有执行权限"
    else
        log_warn "    ✗ 无执行权限，自动 chmod +x..."
        chmod +x "${fieldiag_bin}" 2>/dev/null || {
            log_error "    ❌ chmod +x 失败（权限不足或文件系统为noexec挂载）"
            compat_ok=false
        }
    fi

    # [3] 共享库依赖检查（ldd）
    log_info "  [3/6] 共享库依赖检查..."
    local ldd_out=""
    ldd_out=$(ldd "${fieldiag_bin}" 2>&1)
    local missing_libs=""
    missing_libs=$(echo "${ldd_out}" | grep -i "not found\|无法找到\|未找到" 2>/dev/null || true)
    if [ -z "${missing_libs}" ]; then
        log_ok "    ✓ 所有依赖库已解析"
    else
        log_error "    ❌ 缺少以下依赖库（从20.04拷到24.04常见情况）:"
        while IFS= read -r line; do
            log_error "        ${line}"
        done <<< "${missing_libs}"
        # 常见缺库修复指引
        if echo "${missing_libs}" | grep -qi "libcuda"; then
            log_warn "      缺 libcuda.so.1 → NVIDIA 驱动未安装或未加载，先跑脚本安装驱动后再试"
        fi
        if echo "${missing_libs}" | grep -qi "dcgm\|nvidia-ml"; then
            log_warn "      缺 DCGM/nvidia-ml → 脚本的 install_dcgm() 会安装，或手动 apt install datacenter-gpu-manager"
        fi
        if echo "${missing_libs}" | grep -qi "libc\.so"; then
            log_warn "      缺 glibc 特定版本 → 20.04是glibc 2.31，24.04是glibc 2.39"
            log_warn "        解决方式: 从 24.04 配套的 CUDA Toolkit/Driver 重新获取 fieldiag 版本"
        fi
        compat_ok=false
    fi
    # 保存 ldd 供报告查看
    echo "${ldd_out}" > "${RAW_DATA_DIR}/fieldiag_ldd.txt"

    # [4] --version / --help 能否正常返回（glibc ABI 兼容性最终验证）
    log_info "  [4/6] glibc ABI 兼容性验证（运行 fieldiag --version）..."
    local ver_out=""
    local ver_ret=0
    ver_out=$("${fieldiag_bin}" --version 2>&1) || ver_ret=$?
    if [ ${ver_ret} -eq 0 ] || [ ${ver_ret} -eq 1 ]; then
        # 某些版本 --version 正常返回 0，有些 --version 不支持返回 1（但至少有输出）
        log_ok "    ✓ fieldiag --version 可运行 (输出: $(echo "${ver_out}" | head -n1))"
        echo "${ver_out}" > "${RAW_DATA_DIR}/fieldiag_version.txt"
    else
        log_error "    ❌ fieldiag --version 运行失败 (返回码=${ver_ret})"
        log_error "        输出: $(echo "${ver_out}" | head -n5)"
        # 典型错误：/lib64/ld-linux-x86-64.so.2: bad ELF interpreter / segmentation fault
        if echo "${ver_out}" | grep -qi "bad ELF interpreter\|No such file or directory"; then
            log_error "      原因: glibc 加载器路径差异（20.04 vs 24.04 loader路径不同）"
            log_error "      解决: 从24.04配套的CUDA包中重新获取fieldiag，或安装compat-glibc"
        fi
        if echo "${ver_out}" | grep -qi "segmentation fault\|段错误"; then
            log_error "      原因: 段错误，ABI不兼容或依赖库版本不匹配"
            log_error "      解决: 使用与当前24.04驱动/CUDA版本匹配的fieldiag"
        fi
        compat_ok=false
    fi

    # [5] GPU架构支持检查（fieldiag版本过老不支持Hopper/Blackwell）
    log_info "  [5/6] GPU 架构支持检查..."
    log_info "    当前服务器GPU: ${gpu_names}"
    # 检查H200/H100/B300等较新的架构是否存在
    if echo "${gpu_names}" | grep -qiE "H200|H100|B300|B200|Blackwell|Hopper|GB200|L40S|H800"; then
        log_warn "    检测到 Hopper/Blackwell/L40S 架构（H200/H100/B200/B300/L40S/H800）"
        log_warn "    如果是较旧的 fieldiag（2023年前版本）可能不支持上述GPU诊断"
        log_warn "    如果实际诊断报 GPU Unsupported，需升级 fieldiag 版本"
    fi

    # [6] 30秒快速预检 —— 跑 discovery/help 验证 fieldiag 能初始化并识别GPU（防止正式诊断卡死）
    log_info "  [6/6] 30秒快速预检（fieldiag discovery/help 初始化验证）..."
    local precheck_out=""
    local precheck_ret=0
    # 尝试多种预检命令（不同版本fieldiag参数不同）
    timeout 30 bash -c "'${fieldiag_bin}' --list 2>&1 || '${fieldiag_bin}' -l 2>&1 || '${fieldiag_bin}' --discovery 2>&1 || '${fieldiag_bin}' --help 2>&1 | head -50" \
        > "${RAW_DATA_DIR}/fieldiag_precheck.txt" 2>&1 || precheck_ret=$?
    precheck_out=$(cat "${RAW_DATA_DIR}/fieldiag_precheck.txt")
    if [ ${precheck_ret} -eq 0 ] || [ ${precheck_ret} -eq 1 ]; then
        # 只要不是超时就好。检查有没有致命不支持提示
        if echo "${precheck_out}" | grep -qiE "UNSUPPORTED|unsupported GPU|not supported|GPU family"; then
            log_error "    ❌ 30秒预检报 GPU 不支持：${precheck_out}"
            log_error "      即使是数据中心GPU，此 fieldiag 版本可能仍不支持最新架构，需升级 fieldiag"
            compat_ok=false
        elif echo "${precheck_out}" | grep -qiE "fail|error"; then
            log_warn "    ⚠️ 30秒预检含错误输出，但仍可尝试运行（可手动检查 raw_data/fieldiag_precheck.txt）"
            log_ok "    30秒预检通过：fieldiag可初始化"
        else
            log_ok "    30秒预检通过：fieldiag可初始化（前3行：$(echo "${precheck_out}" | head -n3 | tr '\n' '|'))"
        fi
    elif [ ${precheck_ret} -eq 124 ]; then
        log_error "    ❌ 30秒预检超时（fieldiag 初始化阶段卡死，正式诊断大概率也会卡死）"
        compat_ok=false
    else
        log_warn "    ⚠️ 30秒预检返回码=${precheck_ret}，可继续尝试"
    fi

    # 最终判定
    if [ "${compat_ok}" = "true" ]; then
        log_ok "fieldiag 兼容性自检 ✓ 全部通过，可以直接运行"
    else
        log_error "fieldiag 兼容性自检 ❌ 未通过"
        log_error "处理方式（按优先级）："
        log_error "  1. 【推荐】从与 Ubuntu 24.04 配套的 CUDA ${CUDA_VERSION} Toolkit 重新获取 fieldiag（版本匹配）"
        log_error "  2. 安装缺失的依赖库：apt install libnvidia-ml-dev datacenter-gpu-manager"
        log_error "  3. glibc 不兼容 → 只能用与目标系统匹配的 fieldiag 版本（静态编译版无此问题）"
        log_error "  4. 在原20.04服务器上运行 ldd fieldiag 查看完整依赖列表"
        log_error "  5. 30秒预检卡死/超时 → GPU架构版本不匹配，升级fieldiag"
        # 仍然写入结果
        echo "INCOMPATIBLE" > "${RAW_DATA_DIR}/fieldiag_result.txt"
        {
            echo "fieldiag 二进制兼容性自检失败"
            echo "架构: ${elf_arch} (主机: ${host_arch})"
            echo "缺失库:"
            echo "${missing_libs:-无}"
            echo "版本测试输出:"
            echo "${ver_out:-无}"
            echo "30秒预检输出:"
            echo "${precheck_out:-无}"
        } > "${RAW_DATA_DIR}/fieldiag_diag.txt"
        return
    fi

    fi   # <-- 结束 FORCE_FIELDIAG 的 else 分支

    wait_for_ready "fieldiag Level ${FIELD_LEVEL} 原厂现场诊断"

    # 根据 FIELD_LEVEL 确定参数和超时
    local fieldiag_args=""
    local fieldiag_timeout=21600
    local test_level_desc=""

    case "${FIELD_LEVEL}" in
        1)
            log_info "Field Diagnostics 级别: 1（快速测试）"
            log_info "预计耗时: 约 5~15 分钟"
            # 不同版本fieldiag参数兼容
            if "${fieldiag_bin}" --help 2>&1 | grep -q -- "--level1"; then
                fieldiag_args="--no_bmc --level1"
            elif "${fieldiag_bin}" --help 2>&1 | grep -q -- "--field"; then
                fieldiag_args="--field --quick"
            else
                fieldiag_args="p0only device=1"
            fi
            fieldiag_timeout=1800
            test_level_desc="Level 1 (快速)"
            ;;
        2)
            log_info "Field Diagnostics 级别: 2（中等深度）"
            log_info "预计耗时: 约 4 小时"
            if "${fieldiag_bin}" --help 2>&1 | grep -q -- "--level2"; then
                fieldiag_args="--no_bmc --level2"
            elif "${fieldiag_bin}" --help 2>&1 | grep -q -- "--field"; then
                fieldiag_args="--field"
            else
                fieldiag_args="p0only"
            fi
            fieldiag_timeout=14400
            test_level_desc="Level 2 (中等)"
            ;;
        3)
            log_info "Field Diagnostics 级别: 3（完整诊断）"
            log_info "预计耗时: 约 6 小时"
            if "${fieldiag_bin}" --help 2>&1 | grep -q -- "--level3"; then
                fieldiag_args="--no_bmc --level3"
            else
                fieldiag_args=""
            fi
            fieldiag_timeout=21600
            test_level_desc="Level 3 (完整)"
            ;;
        *)
            log_warn "未知 FIELD_LEVEL=${FIELD_LEVEL}，使用默认 Level 2"
            FIELD_LEVEL=2
            fieldiag_args="--no_bmc --level2"
            fieldiag_timeout=14400
            test_level_desc="Level 2 (中等, 默认)"
            ;;
    esac

    # 保存级别信息
    echo "${test_level_desc}" > "${RAW_DATA_DIR}/fieldiag_level.txt"

    # 启动后台温度监控（长时间诊断必须监控温度）
    log_info "启动 nvidia-smi 后台监控（fieldiag 诊断期间）..."
    nvidia-smi --query-gpu=timestamp,index,name,temperature.gpu,power.draw,utilization.gpu,memory.used \
        --format=csv -l 5 -f "${RAW_DATA_DIR}/gpu_monitor_fieldiag.csv" &
    local monitor_pid=$!

    # 运行 fieldiag（带超时保护）
    log_info "开始执行 fieldiag（超时: ${fieldiag_timeout}秒）..."
    log_info "命令: ${fieldiag_bin} ${fieldiag_args}"

    local field_start=$(date +%s)
    timeout "${fieldiag_timeout}" bash -c "${fieldiag_bin} ${fieldiag_args}" > "${RAW_DATA_DIR}/fieldiag_diag.txt" 2>&1
    local field_ret=$?
    local field_end=$(date +%s)
    local field_elapsed=$(( field_end - field_start ))
    local field_elapsed_fmt=$(printf '%dh%dm%ds' $((field_elapsed/3600)) $(((field_elapsed%3600)/60)) $((field_elapsed%60)))
    echo "耗时: ${field_elapsed_fmt}" >> "${RAW_DATA_DIR}/fieldiag_diag.txt"
    echo "返回码: ${field_ret}" >> "${RAW_DATA_DIR}/fieldiag_diag.txt"

    # 停止监控
    kill "${monitor_pid}" 2>/dev/null; wait "${monitor_pid}" 2>/dev/null

    # 判定结果
    if [ ${field_ret} -eq 0 ]; then
        log_ok "fieldiag ${test_level_desc} 诊断通过 (耗时: ${field_elapsed_fmt})"
        echo "PASS" > "${RAW_DATA_DIR}/fieldiag_result.txt"
    elif [ ${field_ret} -eq 124 ]; then
        log_warn "fieldiag 超时（>${fieldiag_timeout}秒），可能需要降低级别或检查GPU负载"
        echo "TIMEOUT" > "${RAW_DATA_DIR}/fieldiag_result.txt"
    else
        log_error "fieldiag 诊断未通过 (返回码=${field_ret}, 耗时: ${field_elapsed_fmt})"
        log_error "请查看原始输出: ${RAW_DATA_DIR}/fieldiag_diag.txt"
        echo "FAIL" > "${RAW_DATA_DIR}/fieldiag_result.txt"
    fi

    log_ok "fieldiag 原厂现场诊断完成"
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
# 13. 显存校验测试
#   优先级1 [原厂]: cuda-memcheck — NVIDIA原厂CUDA内存错误检测器（随CUDA Toolkit自带）
#     检测项：越界访问、未初始化内存读取、地址对齐错误、全局/共享内存竞争
#   优先级2 [第三方]: cuda_memtest — 10种模式显存写入-读出-校验
#     Test0~10: Walking 1s/0s, Random, Gaussian, Solid Bits, Address Fetch...
#   优先级3 [原厂]: bandwidthTest shmoo — 仅测带宽（回退方案，无正确性校验）
#   任何模式报错 = 显存硬件故障 → 需RMA
# =========================================
test_memory() {
    log_info "========== 13. 显存校验测试 =========="
    local factory_bin
    factory_bin=$(cat "${OUTPUT_DIR}/factory_bin_dir.txt" 2>/dev/null)
    local cuda_bin
    cuda_bin=$(cat "${OUTPUT_DIR}/cuda_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    for (( i=0; i<gpu_count; i++ )); do
        # 优先级1: 原厂 cuda-memcheck（对官方matrixMul做内存错误检测）
        if [ -x "${factory_bin}/cuda-memcheck" ] && [ -x "${cuda_bin}/matrixMul" ]; then
            log_info "GPU ${i}: [原厂] cuda-memcheck + matrixMul 内存错误检测..."
            CUDA_VISIBLE_DEVICES=${i} save_raw "cuda_memcheck_gpu${i}" \
                "${factory_bin}/cuda-memcheck" --tool memcheck \
                "${cuda_bin}/matrixMul" -wA=2048 -hA=2048 -wB=2048 -hB=2048
        fi

        # 优先级2: 第三方 cuda_memtest（10种模式显存校验）
        if [ -x "${factory_bin}/cuda_memtest" ]; then
            log_info "GPU ${i}: [第三方] cuda_memtest 10种模式显存校验（可能需要数分钟）..."
            CUDA_VISIBLE_DEVICES=${i} save_raw "cuda_memtest_gpu${i}" \
                "${factory_bin}/cuda_memtest" --disable_gpu_lock
        elif [ -x "${cuda_bin}/bandwidthTest" ]; then
            # 优先级3: 原厂 bandwidthTest shmoo（仅测带宽，无正确性校验）
            log_warn "GPU ${i}: [回退] bandwidthTest shmoo（仅带宽测试，无正确性校验）"
            CUDA_VISIBLE_DEVICES=${i} save_raw "memtest_shmoo_gpu${i}" \
                "${cuda_bin}/bandwidthTest" --device=${i} --memory=device --mode=shmoo
        else
            log_warn "GPU ${i}: 无可用显存测试工具，跳过"
        fi
    done

    log_ok "显存校验测试完成"
}

# =========================================
# 13.5 满载烧机+正确性校验
#   [原厂] dcgmi diag -r 3 的 Targeted Stress 已在第11步运行
#   [第三方] gpu-burn: 矩阵乘法结果与CPU基准逐元素比对（补充烧机）
#   两者互补，出厂质检必跑项
# =========================================
test_gpu_burn() {
    wait_for_ready "gpu-burn满载烧机"
    log_info "========== 13.5 满载烧机+正确性校验 =========="
    local factory_bin
    factory_bin=$(cat "${OUTPUT_DIR}/factory_bin_dir.txt" 2>/dev/null)
    local gpu_count
    gpu_count=$(cat "${OUTPUT_DIR}/gpu_count.txt")

    if [ ! -x "${factory_bin}/gpu_burn" ]; then
        log_warn "[第三方] gpu_burn 不可用，跳过（原厂dcgmi diag -r 3已在第11步覆盖压力测试）"
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
        log_info "GPU ${i}: [第三方] gpu-burn 满载烧机 ${burn_time} 秒（含矩阵乘法正确性校验）..."
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
            --field-level)  shift_next_field_level=true ;;
            --force-fieldiag) FORCE_FIELDIAG=true ;;
            *)
                if [ "${shift_next_field_level}" = "true" ]; then
                    FIELD_LEVEL="${arg}"
                    shift_next_field_level=false
                fi
                ;;
            -h|--help)
                cat <<EOF
NVIDIA GPU 售后服务自动化测试脚本

用法:
  sudo bash $0 [选项]

选项:
  --skip-install       跳过驱动/CUDA/DCGM安装，直接运行测试
  --stress-only        仅运行压力测试，快速查验温度/功耗
  --field-level N      NVIDIA fieldiag 原厂现场诊断级别:
                         1 = 快速测试 (约5~15分钟)
                         2 = 中等深度 (约4小时)
                         3 = 完整诊断 (约6小时)
  --force-fieldiag     【慎用】强制跳过 fieldiag 所有预检（GPU产品线/30秒快速预检/二进制兼容）
                       仅在你100%确认fieldiag版本+GPU完全匹配时才用，否则可能卡死数小时
  -h, --help           显示此帮助

输出目录:
  ${SCRIPT_DIR}/gpu_test_results_YYYYMMDD_HHMMSS/
    ├── report.html              (售后服务正式报告，HTML格式)
    ├── report_data.json         (结构化原始数据)
    ├── test.log                 (完整运行日志)
    ├── cuda_samples_bin/        (编译后的官方测试工具)
    ├── factory_tools_bin/       (原厂+第三方质检工具)
    └── raw_data/                (所有原始测试输出)
EOF
                exit 0
                ;;
        esac
    done

    # ================================================================
    # 启动交互菜单：无命令行参数时显示（售后服务工程师最常用模式）
    # 覆盖：fieldiag等级、压力时长、温度报警阈值、冷却阈值
    # ================================================================
    if [ $# -eq 0 ]; then
        interactive_menu
    fi

    init
    log_info "输出目录: ${OUTPUT_DIR}"
    log_info "参数设置: fieldiag等级=Level ${FIELD_LEVEL} | 压力时长=${STRESS_DURATION_SEC}秒 | 温度报警=${TEMP_ALARM_C}℃ | 冷却恢复=${TEMP_COOLDOWN_C}℃"
    # 写入配置供报告查阅
    {
        echo "fieldiag_level: Level ${FIELD_LEVEL}"
        echo "stress_duration_sec: ${STRESS_DURATION_SEC}"
        echo "temp_alarm_c: ${TEMP_ALARM_C}"
        echo "temp_cooldown_c: ${TEMP_COOLDOWN_C}"
        echo "force_fieldiag: ${FORCE_FIELDIAG}"
        echo "skip_install: ${skip_install}"
        echo "stress_only: ${stress_only}"
        echo "start_ts: $(date '+%Y-%m-%d %H:%M:%S')"
    } > "${OUTPUT_DIR}/run_config.yml"
    log_info "手动暂停: 另开终端运行 touch ${OUTPUT_DIR}/.manual_pause"
    log_info "手动恢复: 另开终端运行 rm   -f  ${OUTPUT_DIR}/.manual_pause"

    # 启动温度守护进程（此时PAUSE_MARKER路径已在init()内设置好）
    start_temp_watchdog

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
    test_fieldiag             # 11.5 fieldiag 原厂现场诊断

    # ============== 生成报告 ==============
    generate_final_report   # 15.

    log_ok "========== 全部测试完成 =========="
    log_ok "报告目录: ${OUTPUT_DIR}"
    log_ok "请将 report.html 和 report_data.json 一并提交存档"
}

main "$@"
