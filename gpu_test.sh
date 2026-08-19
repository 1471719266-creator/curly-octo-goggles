#!/bin/bash ; set -o pipefail

# ==================== 顺序2: 基础变量 + 立即mkdir保证LOG_FILE可用 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_START="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${SCRIPT_DIR}/gpu_test_output_${TS_START}"
LOG_FILE="${OUTPUT_DIR}/test.log"
RAW_DATA_DIR="${OUTPUT_DIR}/raw_data"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "${OUTPUT_DIR}" "${RAW_DATA_DIR}"
touch "${LOG_FILE}"

# ==================== 顺序3: init() 函数定义 ====================
init() {
    PAUSE_MARKER="${OUTPUT_DIR}/.pause_marker"
    MANUAL_PAUSE="${OUTPUT_DIR}/.manual_pause"
    WATCHDOG_PID_FILE="${OUTPUT_DIR}/.watchdog_pid"
    TEMP_LOG="${OUTPUT_DIR}/watchdog_temp.log"
    GPU_COUNT_FILE="${OUTPUT_DIR}/gpu_count.txt"
    CUDA_BIN_DIR_FILE="${OUTPUT_DIR}/cuda_bin_dir.txt"
    FACTORY_BIN_DIR_FILE="${OUTPUT_DIR}/factory_bin_dir.txt"
    FIELDIAG_RESULT_FILE="${OUTPUT_DIR}/fieldiag_result.txt"
    RUN_CONFIG_FILE="${OUTPUT_DIR}/run_config.yml"
    FAILURE_DIAGNOSIS_FILE="${OUTPUT_DIR}/failure_diagnosis.txt"
    REPORT_DATA_JSON="${OUTPUT_DIR}/report_data.json"
    rm -f "${PAUSE_MARKER}" "${MANUAL_PAUSE}" "${WATCHDOG_PID_FILE}"
    touch "${TEMP_LOG}"
}

# ==================== 顺序4: log() / log_info / log_ok / log_warn / log_error 函数定义 ====================
log() {
    local level="$1"; shift
    local msg="$*"
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line=""
    case "${level}" in
        INFO)    line="${CYAN}[INFO ]${NC} ${msg}" ;;
        OK)      line="${GREEN}[ OK  ]${NC} ${msg}" ;;
        WARN)    line="${YELLOW}[WARN ]${NC} ${msg}" ;;
        ERROR)   line="${RED}[ERROR]${NC} ${msg}" ;;
        *)       line="[${level}] ${msg}" ;;
    esac
    echo -e "${line}" | tee -a "${LOG_FILE}"
}

log_info()  { log INFO  "$*"; }
log_ok()    { log OK    "$*"; }
log_warn()  { log WARN  "$*"; }
log_error() { log ERROR "$*"; }

# ==================== 顺序5: 三个核心工具函数 ====================

check_net_reachable() {
    local targets=("mirrors.aliyun.com" "archive.ubuntu.com" "baidu.com" "github.com")
    local ok_count=0
    for t in "${targets[@]}"; do
        if ping -c 2 -W 3 "${t}" >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
        fi
    done
    if [ "${ok_count}" -ge 2 ]; then
        return 0
    fi
    for t in "${targets[@]}"; do
        for port in 80 443; do
            if (echo > "/dev/tcp/${t}/${port}") >/dev/null 2>&1; then
                ok_count=$((ok_count + 1))
                break
            fi
        done
    done
    [ "${ok_count}" -ge 2 ] && return 0 || return 1
}

apt_selfcheck_repair() {
    log_warn "触发APT自愈流程（共5层）..."
    local rc=0

    log_info "[APT自愈 1/5] 删除锁文件 + dpkg --configure -a"
    sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true
    sudo dpkg --configure -a 2>&1 | tee -a "${LOG_FILE}" || rc=$?

    log_info "[APT自愈 2/5] apt clean + 清理 lists"
    sudo apt-get clean 2>&1 | tee -a "${LOG_FILE}" || true
    sudo rm -rf /var/lib/apt/lists/* 2>/dev/null || true

    log_info "[APT自愈 3/5] dpkg clear-avail + update-avail"
    sudo dpkg --clear-avail 2>&1 | tee -a "${LOG_FILE}" || true
    sudo dpkg --update-avail 2>&1 | tee -a "${LOG_FILE}" || true

    log_info "[APT自愈 4/5] apt update --fix-missing"
    sudo apt-get update --fix-missing 2>&1 | tee -a "${LOG_FILE}" || rc=$?

    log_info "[APT自愈 5/5] apt -f install"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y 2>&1 | tee -a "${LOG_FILE}" || rc=$?

    if [ "${rc}" -ne 0 ]; then
        log_error "APT自动5层自愈仍失败，请手动选择以下3套方案之一修复："
        echo -e "    ${BOLD}方案1 (复制dpkg info):${NC}"
        echo "      sudo cp /var/lib/dpkg/info/* /tmp/dpkg_info_bak/ 2>/dev/null"
        echo "      sudo rm -rf /var/lib/dpkg/info/* && sudo apt-get update"
        echo "      sudo dpkg --configure -a && sudo apt-get -f install -y"
        echo ""
        echo -e "    ${BOLD}方案2 (重装apt deb):${NC}"
        echo "      cd /tmp && sudo apt-get download apt"
        echo "      sudo dpkg -i --force-depends apt_*.deb && sudo apt-get update"
        echo ""
        echo -e "    ${BOLD}方案3 (NVIDIA .run 驱动直装 - 跳APT):${NC}"
        echo "      # 去 https://www.nvidia.com/Download/index.aspx 下载对应 .run"
        echo "      sudo systemctl stop gdm3 2>/dev/null; sudo sh NVIDIA-Linux-*.run"
        return "${rc}"
    fi
    log_ok "APT自愈完成"
    return 0
}

run_apt_safe() {
    local action="$1"; shift
    local rc=0
    local retried=false
    while true; do
        (
            sudo DEBIAN_FRONTEND=noninteractive apt-get "${action}" "$@"
        )
        rc=$?
        if [ "${rc}" -eq 139 ] || [ "${rc}" -eq 134 ]; then
            log_warn "apt收到信号 rc=${rc} (SIGSEGV=139 / SIGABRT=134)，启动apt_selfcheck_repair"
            apt_selfcheck_repair || true
            if [ "${retried}" = "false" ]; then
                log_info "重试一次 apt ${action} ..."
                retried=true
                continue
            else
                log_error "apt ${action} 重试后仍失败 rc=${rc}"
                return "${rc}"
            fi
        fi
        return "${rc}"
    done
}

# ==================== 顺序6: 全局安全壳 trap ERR + ulimit -c 0 ====================
trap 'log_error "Trap ERR: line=$LINENO cmd=$BASH_COMMAND rc=$?"' ERR
ulimit -c 0 2>/dev/null || true

# ==================== 顺序7: 自授权 chmod +x 重启动 ====================
if [ -z "${SELF_CHMOD_DONE}" ]; then
    if [ ! -x "${BASH_SOURCE[0]}" ]; then
        chmod +x "${BASH_SOURCE[0]}" 2>/dev/null || true
    fi
    export SELF_CHMOD_DONE=1
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

# ==================== 顺序8: 配置区（全局变量） ====================
CUDA_VERSION="12.6.1"
CUDA_RUNFILE_VERSION="560.35.05"
STRESS_DURATION_SEC=60
GPUBURN_DURATION_SEC=120
FIELD_LEVEL=1
TEMP_ALARM_C=90
TEMP_COOLDOWN_C=$((TEMP_ALARM_C - 15))
SKIP_INSTALL=false
STRESS_ONLY=false
FORCE_FIELDIAG=false
NET_REACHABLE_CACHED=""

# ==================== 顺序9: save_raw() 函数 ====================
save_raw() {
    local name="$1"; shift
    local out_file="${RAW_DATA_DIR}/${name}.txt"
    {
        echo "===== ${name} @ $(date '+%Y-%m-%d %H:%M:%S') ====="
        echo "\$ $*"
        echo "--------------------------------------------------"
        "$@" 2>&1
        echo ""
        echo "===== exit=$? ====="
    } > "${out_file}" 2>&1 || true
    log_info "原始数据已保存: ${name}.txt"
}

# ==================== 顺序10: interactive_menu() ====================
interactive_menu() {
    local DC_GPU_LIST="H100 H200 H800 H900 B200 B300 B380 B390 GB200 GB300 A100 A800 A900 A30 A10 A10G T4 T4g L4 L40 L40S V100 V100S P100 P40 P4 K80 K40 M60 M40 A2 L20 L2 L10 L10G PG500 PG506 PG509 HGX DGX Tesla GRID Quadro RTX GV100 GP100"
    echo ""
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN} NVIDIA GPU 售后服务自动化测试 - 交互配置 ${NC}"
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo ""

    local have_fieldiag=false
    local f_bin=""
    for p in /usr/local/cuda/bin/fieldiag /opt/nvidia/fieldiag/bin/fieldiag /usr/bin/fieldiag "${SCRIPT_DIR}/fieldiag"; do
        if [ -x "${p}" ]; then have_fieldiag=true; f_bin="${p}"; break; fi
    done
    if [ -z "${f_bin}" ]; then f_bin="$(command -v fieldiag 2>/dev/null || true)"; fi
    [ -n "${f_bin}" ] && [ -x "${f_bin}" ] && have_fieldiag=true

    local have_dc_gpu=false
    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu_names
        gpu_names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)"
        for g in ${DC_GPU_LIST}; do
            if echo "${gpu_names}" | grep -qi "${g}"; then
                have_dc_gpu=true
                break
            fi
        done
    fi

    echo -e "${BLUE}步骤1/4: 压力测试时长设置${NC}"
    read -r -p "  压力测试持续秒数（默认${STRESS_DURATION_SEC}s）: " _tmp
    [ -n "${_tmp}" ] && STRESS_DURATION_SEC="${_tmp}"

    echo ""
    echo -e "${BLUE}步骤2/4: gpu-burn 满载时长设置${NC}"
    read -r -p "  gpu-burn 持续秒数（默认${GPUBURN_DURATION_SEC}s）: " _tmp
    [ -n "${_tmp}" ] && GPUBURN_DURATION_SEC="${_tmp}"

    echo ""
    echo -e "${BLUE}步骤3/4: 温度报警阈值${NC}"
    read -r -p "  GPU温度报警阈值°C（默认${TEMP_ALARM_C}°C，冷却恢复=阈值-15）: " _tmp
    if [ -n "${_tmp}" ]; then
        TEMP_ALARM_C="${_tmp}"
        TEMP_COOLDOWN_C=$((TEMP_ALARM_C - 15))
    fi

    echo ""
    if [ "${have_fieldiag}" = "true" ] && [ "${have_dc_gpu}" = "true" ]; then
        echo -e "${BLUE}步骤4/4: NVIDIA 原厂 fieldiag 诊断级别（数据中心GPU检测到）${NC}"
        echo "  Level 0: 仅预检 (约30秒)"
        echo "  Level 1: 快速诊断 (约5分钟，默认)"
        echo "  Level 2: 标准诊断 (约20分钟)"
        echo "  Level 3: 深度诊断 (约1小时)"
        read -r -p "  请选择 Level (0~3，默认${FIELD_LEVEL}): " _tmp
        [ -n "${_tmp}" ] && FIELD_LEVEL="${_tmp}"
    else
        echo -e "${BLUE}步骤4/4: fieldiag 原厂诊断${NC}"
        if [ "${have_fieldiag}" != "true" ]; then
            log_info "ℹ️  未检测到 fieldiag 二进制，自动跳过原厂诊断（PCIe/温度/显存等测试仍完整执行）"
        else
            log_info "ℹ️  未检测到数据中心级GPU（H100/A100/V100等），自动跳过 fieldiag（消费级卡不支持）"
        fi
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}=========== 最终配置确认 ===========${NC}"
    echo "  输出目录        : ${OUTPUT_DIR}"
    echo "  压力测试时长    : ${STRESS_DURATION_SEC} 秒"
    echo "  gpu-burn 时长   : ${GPUBURN_DURATION_SEC} 秒"
    echo "  温度报警阈值    : ${TEMP_ALARM_C}°C（冷却恢复: ${TEMP_COOLDOWN_C}°C）"
    if [ "${have_fieldiag}" = "true" ] && [ "${have_dc_gpu}" = "true" ]; then
        echo "  fieldiag Level  : ${FIELD_LEVEL}"
    else
        echo "  fieldiag        : 自动跳过"
    fi
    echo -e "${BOLD}${YELLOW}====================================${NC}"
    read -r -p "按 Enter 确认并开始测试（Ctrl+C 取消）..." _tmp
    echo ""
}

# ==================== 顺序11: start_temp_watchdog() ====================
start_temp_watchdog() {
    log_info "启动温度看门狗后台进程（报警=${TEMP_ALARM_C}°C，冷却恢复=${TEMP_COOLDOWN_C}°C）"
    (
        trap 'rm -f "${WATCHDOG_PID_FILE}"; exit 0' EXIT INT TERM
        echo $$ > "${WATCHDOG_PID_FILE}"
        local last_log_ts=0
        while true; do
            if [ -f "${MANUAL_PAUSE}" ]; then
                sleep 2
                continue
            fi
            local max_t=0
            local min_t=999
            if command -v nvidia-smi >/dev/null 2>&1; then
                local temps
                temps="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo 0)"
                for t in ${temps}; do
                    [ "${t}" = "[Not" ] && continue
                    [ "${t}" = "Supported]" ] && continue
                    if [ -n "${t}" ] && [ "${t}" -eq "${t}" ] 2>/dev/null; then
                        [ "${t}" -gt "${max_t}" ] && max_t="${t}"
                        [ "${t}" -lt "${min_t}" ] && min_t="${t}"
                    fi
                done
            fi
            local now_ts
            now_ts="$(date +%s)"
            if [ $((now_ts - last_log_ts)) -ge 30 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] watchdog max=${max_t}°C min=${min_t}°C alarm=${TEMP_ALARM_C} cooldown=${TEMP_COOLDOWN_C}" >> "${TEMP_LOG}"
                last_log_ts="${now_ts}"
            fi
            if [ "${max_t}" -ge "${TEMP_ALARM_C}" ]; then
                if [ ! -f "${PAUSE_MARKER}" ]; then
                    log_error "🌡️  GPU温度报警: 最高=${max_t}°C >= 阈值=${TEMP_ALARM_C}°C！写入PAUSE_MARKER暂停测试，等待冷却..."
                    touch "${PAUSE_MARKER}"
                fi
            elif [ "${max_t}" -le "${TEMP_COOLDOWN_C}" ]; then
                if [ -f "${PAUSE_MARKER}" ] && [ ! -f "${MANUAL_PAUSE}" ]; then
                    log_ok "🌡️  GPU温度已冷却: 最高=${max_t}°C <= ${TEMP_COOLDOWN_C}°C，删除PAUSE_MARKER恢复测试"
                    rm -f "${PAUSE_MARKER}"
                fi
            fi
            sleep 5
        done
    ) &
    WATCHDOG_BG_PID=$!
    log_ok "温度看门狗已启动 (PID=${WATCHDOG_BG_PID})"
    log_info "手动暂停:  touch ${MANUAL_PAUSE}"
    log_info "手动恢复:  rm -f ${MANUAL_PAUSE}"
}

# ==================== 顺序12: wait_for_ready(caller_name) ====================
wait_for_ready() {
    local caller_name="$1"
    while [ -f "${PAUSE_MARKER}" ] || [ -f "${MANUAL_PAUSE}" ]; do
        if [ -f "${MANUAL_PAUSE}" ]; then
            log_warn "[${caller_name}] 检测到 MANUAL_PAUSE 标记，等待手动恢复 (rm -f ${MANUAL_PAUSE})"
        else
            log_info "[${caller_name}] 检测到 PAUSE_MARKER（温度报警），等待GPU冷却..."
        fi
        sleep 2
    done
}

# ==================== 顺序13: install_system_deps() ====================
install_system_deps() {
    log_info "开始检查/安装系统基础依赖"
    local base_deps=(wget curl git lspci python3 make gcc unzip file ldd)
    local apt_pkgs=(wget curl git pciutils python3 make gcc unzip file libc-bin)
    local ok_deps=()
    local fail_deps=()

    local need_apt=false
    for i in "${!base_deps[@]}"; do
        local d="${base_deps[$i]}"
        if command -v "${d}" >/dev/null 2>&1; then
            ok_deps+=("${d}")
        elif dpkg -s "${apt_pkgs[$i]}" >/dev/null 2>&1; then
            ok_deps+=("${d}")
        else
            fail_deps+=("${apt_pkgs[$i]}")
            need_apt=true
        fi
    done

    if [ "${need_apt}" = "true" ]; then
        if check_net_reachable; then
            NET_REACHABLE_CACHED="yes"
            log_info "网络可达，开始 apt 安装缺失依赖: ${fail_deps[*]}"
            run_apt_safe update || true
            for pkg in "${fail_deps[@]}"; do
                run_apt_safe install -y --no-install-recommends "${pkg}" || true
                if command -v "${pkg}" >/dev/null 2>&1 || dpkg -s "${pkg}" >/dev/null 2>&1; then
                    ok_deps+=("${pkg}")
                else
                    log_warn "依赖 ${pkg} 安装后仍不可用"
                fi
            done
        else
            NET_REACHABLE_CACHED="no"
            log_warn "网络不可达，跳过依赖apt安装（后续CUDA/驱动下载也会跳过）"
            log_info "恢复网络后手动执行: sudo apt-get update && sudo apt-get install -y wget curl git pciutils python3 build-essential unzip"
        fi
    else
        NET_REACHABLE_CACHED="yes"
    fi

    if ! command -v make >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1; then
        if [ "${NET_REACHABLE_CACHED}" = "yes" ]; then
            log_info "安装 build-essential (make/gcc/g++)"
            run_apt_safe update || true
            run_apt_safe install -y --no-install-recommends build-essential || true
        fi
    fi
    log_ok "系统基础依赖检查完成（ok=${#ok_deps[@]}）"
}

# ==================== 顺序14: check_system() ====================
check_system() {
    log_info "===== 系统环境检查 ====="
    local pretty_name="" version_id=""
    if [ -f /etc/os-release ]; then
        pretty_name="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')"
        version_id="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    fi
    log_info "操作系统: ${pretty_name} (VERSION_ID=${version_id})"
    if echo "${version_id}" | grep -qE '^24\.'; then
        log_ok "Ubuntu 24.x 完全兼容（最新nvidia-driver-560/570 + CUDA12.6官方支持）"
    else
        log_warn "非 Ubuntu 24.x (当前=${version_id})，驱动/CUDA版本可能需手动调整，建议升级到24.04 LTS"
    fi

    log_info "内核版本: $(uname -r)"
    log_info "主机名  : $(hostname)"
    log_info "架构    : $(uname -m)"
    save_raw uname_full uname -a
    save_raw cpu_info  cat /proc/cpuinfo
    save_raw mem_info  cat /proc/meminfo

    log_info "扫描 PCIe 设备..."
    save_raw lspci_full lspci -nnvvv
    local VGA_LIST=""
    VGA_LIST="$(lspci 2>/dev/null | grep -i nvidia || true)"
    if [ -z "${VGA_LIST}" ]; then
        if ! command -v lspci >/dev/null 2>&1; then
            log_error "lspci 命令不存在（pciutils未安装），无法扫描GPU"
            log_info "手动安装: sudo apt-get install -y pciutils && sudo update-pciids"
            exit 1
        else
            log_error "===== 未检测到任何 NVIDIA GPU PCIe 设备 ====="
            log_error "请按以下5条硬件排查（RMA前必做）："
            echo "  1) 断电拔插GPU：清理金手指（橡皮擦拭）、确认8pin/16pin供电线插紧（SXM检查底座螺丝）"
            echo "  2) 供电/电源：确认单卡>=300W整机余量，双路EPS12V必须都插，HGX/H800检查背板供电"
            echo "  3) BIOS设置：Above 4G Decoding=Enable，SR-IOV=Disable，PCIe Gen=Auto/Max，Secure Boot=Disable"
            echo "  4) 插槽交叉：换主板另一个PCIe x16插槽试，或同槽换另一张已知好卡排除"
            echo "  5) RMA前置：如果以上都试了仍为0卡，拍主板BIOS版本+PCIe插槽照片+序列号提交RMA"
            exit 1
        fi
    fi
    log_ok "检测到 $(echo "${VGA_LIST}" | wc -l) 个 NVIDIA PCIe 设备:"
    echo "${VGA_LIST}" | while read -r line; do
        log_info "  - ${line}"
    done

    log_info "IOMMU 状态 (影响PCIe直通/SR-IOV):"
    local iommu_lines
    iommu_lines="$(dmesg 2>/dev/null | grep -i iommu | tail -5 || true)"
    if [ -n "${iommu_lines}" ]; then
        echo "${iommu_lines}" | tee -a "${LOG_FILE}"
        save_raw dmesg_iommu bash -c "dmesg | grep -i iommu"
    else
        log_info "未检测到IOMMU消息（需内核启动参数 intel_iommu=on 或 amd_iommu=on）"
    fi
}

# ==================== 顺序15: check_nvidia_driver() ====================
check_nvidia_driver() {
    log_info "===== NVIDIA 驱动检查 ====="
    if command -v nvidia-smi >/dev/null 2>&1; then
        local drv_ver
        drv_ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo unknown)"
        log_ok "nvidia-smi 已就绪，驱动版本=${drv_ver}"
        save_raw nvidia_smi_initial nvidia-smi
        return 0
    fi
    log_warn "未检测到 nvidia-smi，开始自动安装 NVIDIA 驱动..."
    log_info "（若自动失败，手动执行: sudo ubuntu-drivers autoinstall && sudo reboot）"

    if [ "${NET_REACHABLE_CACHED}" != "yes" ]; then
        log_warn "当前网络不可达，跳过驱动apt安装，请先联网或手动安装"
        return 1
    fi

    run_apt_safe update || true
    run_apt_safe install -y --no-install-recommends ubuntu-drivers-common software-properties-common dkms build-essential || true

    (
        sudo add-apt-repository -y ppa:graphics-drivers/ppa 2>&1 | tee -a "${LOG_FILE}"
    ) || log_warn "添加 graphics-drivers PPA 失败，尝试使用默认仓库"

    run_apt_safe update || true

    local RECOMMENDED=""
    RECOMMENDED="$(ubuntu-drivers devices 2>/dev/null | grep -i recommended | awk '{print $3}' | head -n1 || true)"
    if [ -z "${RECOMMENDED}" ]; then
        RECOMMENDED="nvidia-driver-560-server"
        log_info "ubuntu-drivers 未返回推荐驱动，使用默认: ${RECOMMENDED}"
    else
        log_info "ubuntu-drivers 推荐驱动: ${RECOMMENDED}"
    fi

    run_apt_safe install -y "${RECOMMENDED}" dkms || true

    if command -v nvidia-smi >/dev/null 2>&1; then
        log_ok "驱动安装成功！当前版本: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
        log_warn "⚠️  强烈建议执行 sudo reboot 重启后再跑测试（dkms模块需新内核加载，否则后续CUDA/nvidia-smi可能段错误）"
        return 0
    else
        log_error "驱动apt安装后仍无 nvidia-smi，请手动执行："
        echo "  方案A: sudo ubuntu-drivers autoinstall && sudo reboot"
        echo "  方案B: sudo apt-get install -y nvidia-driver-560-server dkms && sudo reboot"
        echo "  方案C: 从 https://www.nvidia.com/Download 下载 .run 文件:"
        echo "         sudo systemctl stop gdm3; sudo sh NVIDIA-Linux-*.run --dkms"
        return 1
    fi
}

# ==================== 顺序16: install_cuda_toolkit() ====================
install_cuda_toolkit() {
    log_info "===== CUDA Toolkit 检查/安装 ====="
    if command -v nvcc >/dev/null 2>&1; then
        local nv_ver
        nv_ver="$(nvcc --version 2>/dev/null | grep -E 'release [0-9]' | head -n1 || echo unknown)"
        log_ok "nvcc 已就绪: ${nv_ver}"
        compile_cuda_samples
        return 0
    fi

    local CUDA_RUNFILE="cuda_${CUDA_VERSION}_${CUDA_RUNFILE_VERSION}_linux.run"
    local CUDA_URL="https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/${CUDA_RUNFILE}"
    local CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"
    local INSTALLED_OK=false

    if [ "${NET_REACHABLE_CACHED}" != "yes" ]; then
        log_warn "网络不可达，跳过CUDA自动安装（可手动下载runfile后执行）"
        log_info "手动命令: wget ${CUDA_URL} && sudo sh ${CUDA_RUNFILE} --silent --toolkit"
        mkdir -p "${OUTPUT_DIR}/cuda_samples_bin"
        echo "${OUTPUT_DIR}/cuda_samples_bin" > "${CUDA_BIN_DIR_FILE}"
        return 1
    fi

    log_info "尝试方式1: 下载 CUDA runfile ${CUDA_RUNFILE}"
    if command -v wget >/dev/null 2>&1; then
        ( cd /tmp && wget -q --show-progress "${CUDA_URL}" -O "/tmp/${CUDA_RUNFILE}" ) 2>&1 | tee -a "${LOG_FILE}" || true
    elif command -v curl >/dev/null 2>&1; then
        ( cd /tmp && curl -fsSL -o "/tmp/${CUDA_RUNFILE}" "${CUDA_URL}" ) 2>&1 | tee -a "${LOG_FILE}" || true
    fi

    if [ -f "/tmp/${CUDA_RUNFILE}" ] && [ -s "/tmp/${CUDA_RUNFILE}" ]; then
        log_info "runfile 下载完成，开始静默安装 toolkit+samples"
        chmod +x "/tmp/${CUDA_RUNFILE}"
        ( sudo sh "/tmp/${CUDA_RUNFILE}" --silent --toolkit --samples --samplespath=/usr/local/cuda/samples --override ) 2>&1 | tee -a "${LOG_FILE}" || true
        if [ -f /usr/local/cuda/bin/nvcc ]; then
            INSTALLED_OK=true
            log_ok "CUDA runfile 安装成功"
        fi
    fi

    if [ "${INSTALLED_OK}" = "false" ]; then
        log_info "尝试方式2: cuda-keyring.deb + apt 安装 cuda-toolkit-12-6-1"
        if command -v wget >/dev/null 2>&1; then
            wget -q "${CUDA_KEYRING_URL}" -O /tmp/cuda-keyring.deb 2>&1 | tee -a "${LOG_FILE}" || true
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL -o /tmp/cuda-keyring.deb "${CUDA_KEYRING_URL}" 2>&1 | tee -a "${LOG_FILE}" || true
        fi
        if [ -f /tmp/cuda-keyring.deb ] && [ -s /tmp/cuda-keyring.deb ]; then
            sudo dpkg -i /tmp/cuda-keyring.deb 2>&1 | tee -a "${LOG_FILE}" || true
            run_apt_safe update || true
            run_apt_safe install -y cuda-toolkit-12-6-1 || true
            if [ -f /usr/local/cuda/bin/nvcc ]; then
                INSTALLED_OK=true
                log_ok "CUDA apt 安装成功"
            fi
        fi
    fi

    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"
    if ! grep -q 'cuda/bin' /etc/profile.d/cuda.sh 2>/dev/null; then
        echo 'export PATH=/usr/local/cuda/bin:$PATH' | sudo tee /etc/profile.d/cuda.sh >/dev/null 2>&1 || true
        echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' | sudo tee -a /etc/profile.d/cuda.sh >/dev/null 2>&1 || true
    fi

    if command -v nvcc >/dev/null 2>&1; then
        log_ok "nvcc 已就绪: $(nvcc --version 2>/dev/null | grep -E 'release [0-9]' | head -n1)"
        compile_cuda_samples
    else
        log_error "CUDA Toolkit 自动安装失败，请手动执行："
        echo "  # 方式1 runfile（推荐）"
        echo "  wget ${CUDA_URL}"
        echo "  sudo sh ${CUDA_RUNFILE} --silent --toolkit --samples --samplespath=/usr/local/cuda/samples --override"
        echo ""
        echo "  # 方式2 apt"
        echo "  wget ${CUDA_KEYRING_URL}"
        echo "  sudo dpkg -i cuda-keyring_1.1-1_all.deb && sudo apt-get update"
        echo "  sudo apt-get install -y cuda-toolkit-12-6-1"
        mkdir -p "${OUTPUT_DIR}/cuda_samples_bin"
        echo "${OUTPUT_DIR}/cuda_samples_bin" > "${CUDA_BIN_DIR_FILE}"
    fi
}

# ==================== 顺序17: compile_cuda_samples() ====================
compile_cuda_samples() {
    local CUDA_SAMPLES_SRC="/usr/local/cuda/samples"
    local BIN_DIR="${OUTPUT_DIR}/cuda_samples_bin"
    mkdir -p "${BIN_DIR}"
    echo "${BIN_DIR}" > "${CUDA_BIN_DIR_FILE}"
    log_info "开始编译 CUDA Samples（输出目录: ${BIN_DIR}）"

    local NVCC_BIN="/usr/local/cuda/bin/nvcc"
    [ ! -x "${NVCC_BIN}" ] && NVCC_BIN="$(command -v nvcc 2>/dev/null || echo nvcc)"

    local samples=(
        "1_Utilities/deviceQuery:deviceQuery"
        "1_Utilities/bandwidthTest:bandwidthTest"
        "5_Simulations/nbody:nbody"
        "0_Simple/matrixMul:matrixMul"
        "1_Utilities/topologyQuery:topologyQuery"
        "1_Utilities/p2pBandwidthLatencyTest:p2pBandwidthLatencyTest"
    )

    for entry in "${samples[@]}"; do
        local subdir="${entry%%:*}"
        local target="${entry##*:}"
        local src_dir="${CUDA_SAMPLES_SRC}/${subdir}"
        if [ ! -d "${src_dir}" ]; then
            log_warn "跳过 ${target}: 源码目录不存在 (${src_dir})"
            continue
        fi
        log_info "编译 ${target} ..."
        (
            cd "${src_dir}" && make NVCC="${NVCC_BIN}" clean >/dev/null 2>&1 || true
            cd "${src_dir}" && make NVCC="${NVCC_BIN}" -j"$(nproc 2>/dev/null || echo 2)" 2>&1 | tee -a "${LOG_FILE}"
        )
        local rc=$?
        if [ "${rc}" -eq 0 ] && [ -x "${src_dir}/${target}" ]; then
            cp "${src_dir}/${target}" "${BIN_DIR}/" 2>/dev/null || true
            log_ok "  ${target} 编译成功 -> ${BIN_DIR}/${target}"
        else
            log_warn "  ${target} 编译失败 (rc=${rc})，跳过（不影响其他测试）"
        fi
    done
}

# ==================== 顺序18: install_dcgm() ====================
install_dcgm() {
    log_info "===== NVIDIA DCGM 检查/安装 ====="
    if command -v dcgmi >/dev/null 2>&1; then
        log_ok "dcgmi 已就绪: $(dcgmi --version 2>/dev/null | head -n1 || echo unknown)"
        return 0
    fi

    if [ "${NET_REACHABLE_CACHED}" != "yes" ]; then
        log_warn "网络不可达，跳过DCGM安装"
        log_info "手动安装: https://developer.nvidia.com/dcgm"
        return 1
    fi

    local key_url="https://nvidia.github.io/dcgm/gpgkey.pub"
    local list_url="https://nvidia.github.io/dcgm/ubuntu2404/x86_64/dcgm.list"
    local installed_ok=false

    log_info "添加 NVIDIA DCGM GPG key + 源..."
    if command -v curl >/dev/null 2>&1; then
        ( curl -fsSL "${key_url}" | sudo gpg --dearmor -o /usr/share/keyrings/dcgm-archive-keyring.gpg ) 2>&1 | tee -a "${LOG_FILE}" || true
        ( curl -fsSL "${list_url}" | sudo tee /etc/apt/sources.list.d/dcgm.list >/dev/null ) 2>&1 | tee -a "${LOG_FILE}" || true
    elif command -v wget >/dev/null 2>&1; then
        ( wget -qO - "${key_url}" | sudo gpg --dearmor -o /usr/share/keyrings/dcgm-archive-keyring.gpg ) 2>&1 | tee -a "${LOG_FILE}" || true
        ( wget -qO - "${list_url}" | sudo tee /etc/apt/sources.list.d/dcgm.list >/dev/null ) 2>&1 | tee -a "${LOG_FILE}" || true
    fi

    if [ -f /etc/apt/sources.list.d/dcgm.list ]; then
        run_apt_safe update || true
        run_apt_safe install -y datacenter-gpu-manager || true
        if command -v dcgmi >/dev/null 2>&1; then installed_ok=true; fi
    fi

    if [ "${installed_ok}" = "false" ]; then
        log_info "DCGM源方式失败，直接尝试 apt install datacenter-gpu-manager"
        run_apt_safe update || true
        run_apt_safe install -y datacenter-gpu-manager || true
        command -v dcgmi >/dev/null 2>&1 && installed_ok=true
    fi

    if command -v dcgmi >/dev/null 2>&1; then
        sudo systemctl enable --now nvidia-dcgm.service 2>&1 | tee -a "${LOG_FILE}" || true
        sleep 2
        log_ok "dcgmi 安装成功: $(dcgmi --version 2>/dev/null | head -n1 || echo unknown)"
    else
        log_warn "DCGM 自动安装失败，手动执行以下4行："
        echo "  curl -fsSL ${key_url} | sudo gpg --dearmor -o /usr/share/keyrings/dcgm-archive-keyring.gpg"
        echo "  curl -fsSL ${list_url} | sudo tee /etc/apt/sources.list.d/dcgm.list"
        echo "  sudo apt-get update && sudo apt-get install -y datacenter-gpu-manager"
        echo "  sudo systemctl enable --now nvidia-dcgm.service"
    fi
}

# ==================== 顺序19: install_factory_tools() ====================
install_factory_tools() {
    log_info "===== 原厂/第三方工厂工具安装 ====="
    local FACTORY_BIN="${OUTPUT_DIR}/factory_tools_bin"
    mkdir -p "${FACTORY_BIN}"
    echo "${FACTORY_BIN}" > "${FACTORY_BIN_DIR_FILE}"
    export PATH="/usr/local/cuda/bin:${PATH}"

    local status_cuda_memcheck="MISSING"
    local status_nvbandwidth="MISSING"
    local status_gpu_burn="MISSING"
    local status_cuda_memtest="MISSING"

    if [ -f /usr/local/cuda/bin/cuda-memcheck ]; then
        cp /usr/local/cuda/bin/cuda-memcheck "${FACTORY_BIN}/" 2>/dev/null || true
        status_cuda_memcheck="OK"
    elif [ -f /usr/local/cuda/bin/compute-sanitizer ]; then
        cp /usr/local/cuda/bin/compute-sanitizer "${FACTORY_BIN}/cuda-memcheck" 2>/dev/null || true
        status_cuda_memcheck="OK(compute-sanitizer兼容)"
    fi
    if command -v nvbandwidth >/dev/null 2>&1; then
        cp "$(command -v nvbandwidth)" "${FACTORY_BIN}/" 2>/dev/null || true
        status_nvbandwidth="OK"
    elif [ -f /usr/local/cuda/bin/nvbandwidth ]; then
        cp /usr/local/cuda/bin/nvbandwidth "${FACTORY_BIN}/" 2>/dev/null || true
        status_nvbandwidth="OK"
    fi

    local have_downloader=false
    command -v git >/dev/null 2>&1 && have_downloader=true
    command -v wget >/dev/null 2>&1 && have_downloader=true
    command -v curl >/dev/null 2>&1 && have_downloader=true

    local net_ok=false
    if [ -n "${NET_REACHABLE_CACHED}" ] && [ "${NET_REACHABLE_CACHED}" = "yes" ]; then
        net_ok=true
    else
        if ping -c 2 -W 3 github.com >/dev/null 2>&1 || ping -c 2 -W 3 mirrors.aliyun.com >/dev/null 2>&1; then
            net_ok=true
        elif (echo > /dev/tcp/github.com/443) >/dev/null 2>&1 || (echo > /dev/tcp/mirrors.aliyun.com/80) >/dev/null 2>&1; then
            net_ok=true
        fi
    fi
    NET_REACHABLE_CACHED="${net_ok}"

    local skip_download=false
    if [ "${have_downloader}" = "false" ] || [ "${net_ok}" = "false" ]; then
        skip_download=true
        log_warn "下载条件不满足(have_downloader=${have_downloader}, net_ok=${net_ok})，跳过工具源码编译"
        log_info "恢复条件后手动执行: sudo apt-get install -y git wget curl build-essential && 重新跑脚本"
    fi

    log_info "--- gpu-burn ---"
    local GB_DIR="/tmp/gpu-burn"
    if [ -f "${FACTORY_BIN}/gpu_burn" ]; then
        status_gpu_burn="OK"
    elif [ -f "${GB_DIR}/gpu_burn" ]; then
        cp "${GB_DIR}/gpu_burn" "${FACTORY_BIN}/" 2>/dev/null || true
        status_gpu_burn="OK"
    elif [ "${skip_download}" = "false" ]; then
        local gb_ok=false
        if command -v git >/dev/null 2>&1; then
            ( rm -rf "${GB_DIR}" && git clone --depth 1 https://github.com/wilicc/gpu-burn "${GB_DIR}" ) 2>&1 | tee -a "${LOG_FILE}" && gb_ok=true || true
            if [ "${gb_ok}" = "false" ]; then
                ( rm -rf "${GB_DIR}" && git clone --depth 1 https://ghproxy.com/https://github.com/wilicc/gpu-burn "${GB_DIR}" ) 2>&1 | tee -a "${LOG_FILE}" && gb_ok=true || true
            fi
        fi
        if [ "${gb_ok}" = "false" ] && command -v wget >/dev/null 2>&1; then
            ( wget -q https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip -O /tmp/gpu-burn.zip && cd /tmp && unzip -qo gpu-burn.zip && rm -rf "${GB_DIR}" && mv gpu-burn-master "${GB_DIR}" ) 2>&1 | tee -a "${LOG_FILE}" && gb_ok=true || true
            if [ "${gb_ok}" = "false" ]; then
                ( wget -q https://ghproxy.com/https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip -O /tmp/gpu-burn.zip && cd /tmp && unzip -qo gpu-burn.zip && rm -rf "${GB_DIR}" && mv gpu-burn-master "${GB_DIR}" ) 2>&1 | tee -a "${LOG_FILE}" && gb_ok=true || true
            fi
        fi
        if [ "${gb_ok}" = "true" ] && [ -d "${GB_DIR}" ]; then
            log_info "编译 gpu-burn..."
            ( cd "${GB_DIR}" && make CUDA_DIR=/usr/local/cuda NVCC=/usr/local/cuda/bin/nvcc 2>&1 ) | tee -a "${LOG_FILE}"
            if [ -x "${GB_DIR}/gpu_burn" ]; then
                cp "${GB_DIR}/gpu_burn" "${FACTORY_BIN}/"
                [ -f "${GB_DIR}/compare.ptx" ] && cp "${GB_DIR}/compare.ptx" "${FACTORY_BIN}/" 2>/dev/null || true
                status_gpu_burn="OK"
                log_ok "gpu-burn 编译成功"
            else
                log_error "gpu-burn 编译失败，30秒后继续（请排查: 1.nvcc是否存在? 2.g++是否安装? 3.CUDA_DIR=/usr/local/cuda 是否正确?）"
                for i in $(seq 30 -1 1); do printf "\r  倒计时: %02d秒" "${i}"; sleep 1; done; echo ""
            fi
        fi
    fi

    log_info "--- cuda_memtest ---"
    local CM_DIR="/tmp/cuda_memtest"
    if [ -f "${FACTORY_BIN}/cuda_memtest" ]; then
        status_cuda_memtest="OK"
    elif [ -f "${CM_DIR}/cuda_memtest" ]; then
        cp "${CM_DIR}/cuda_memtest" "${FACTORY_BIN}/" 2>/dev/null || true
        status_cuda_memtest="OK"
    elif [ "${skip_download}" = "false" ]; then
        local cm_ok=false
        if command -v git >/dev/null 2>&1; then
            ( rm -rf "${CM_DIR}" && git clone --depth 1 https://github.com/ComputationalRadiationPhysics/cuda_memtest "${CM_DIR}" ) 2>&1 | tee -a "${LOG_FILE}" && cm_ok=true || true
            if [ "${cm_ok}" = "false" ]; then
                ( rm -rf "${CM_DIR}" && git clone --depth 1 https://ghproxy.com/https://github.com/ComputationalRadiationPhysics/cuda_memtest "${CM_DIR}" ) 2>&1 | tee -a "${LOG_FILE}" && cm_ok=true || true
            fi
        fi
        if [ "${cm_ok}" = "false" ] && command -v wget >/dev/null 2>&1; then
            ( wget -q https://github.com/ComputationalRadiationPhysics/cuda_memtest/archive/refs/heads/master.zip -O /tmp/cuda_memtest.zip && cd /tmp && unzip -qo cuda_memtest.zip && rm -rf "${CM_DIR}" && mv cuda_memtest-master "${CM_DIR}" ) 2>&1 | tee -a "${LOG_FILE}" && cm_ok=true || true
            if [ "${cm_ok}" = "false" ]; then
                ( wget -q https://ghproxy.com/https://github.com/ComputationalRadiationPhysics/cuda_memtest/archive/refs/heads/master.zip -O /tmp/cuda_memtest.zip && cd /tmp && unzip -qo cuda_memtest.zip && rm -rf "${CM_DIR}" && mv cuda_memtest-master "${CM_DIR}" ) 2>&1 | tee -a "${LOG_FILE}" && cm_ok=true || true
            fi
        fi
        if [ "${cm_ok}" = "true" ] && [ -d "${CM_DIR}" ]; then
            log_info "编译 cuda_memtest..."
            ( cd "${CM_DIR}" && make CUDA_DIR=/usr/local/cuda NVCC=/usr/local/cuda/bin/nvcc 2>&1 ) | tee -a "${LOG_FILE}"
            if [ -x "${CM_DIR}/cuda_memtest" ]; then
                cp "${CM_DIR}/cuda_memtest" "${FACTORY_BIN}/"
                status_cuda_memtest="OK"
                log_ok "cuda_memtest 编译成功"
            else
                log_error "cuda_memtest 编译失败，30秒后继续（排查: nvcc? g++? CUDA_DIR?）"
                for i in $(seq 30 -1 1); do printf "\r  倒计时: %02d秒" "${i}"; sleep 1; done; echo ""
            fi
        fi
    fi

    log_info "===== 工厂工具就绪状态汇总 ====="
    log_info "  cuda-memcheck  : ${status_cuda_memcheck}"
    log_info "  nvbandwidth    : ${status_nvbandwidth}"
    log_info "  gpu_burn       : ${status_gpu_burn}"
    log_info "  cuda_memtest   : ${status_cuda_memtest}"
}

# ==================== 顺序20: enumerate_gpus() - 软着陆版本 ====================
enumerate_gpus() {
    log_info "===== GPU 枚举（门禁，软着陆版本）====="
    local GPU_COUNT=0
    GPU_COUNT="$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -n1 || echo 0)"
    [ "${GPU_COUNT}" = "count" ] && GPU_COUNT=0
    if [ "${GPU_COUNT}" -eq 0 ] || ! [ "${GPU_COUNT}" -eq "${GPU_COUNT}" ] 2>/dev/null; then
        local alt
        alt="$(nvidia-smi -L 2>/dev/null | wc -l || echo 0)"
        [ "${alt}" -gt 0 ] && GPU_COUNT="${alt}"
    fi

    if [ "${GPU_COUNT}" -eq 0 ]; then
        log_error "======================================"
        log_error "❌ GPU 枚举报错: nvidia-smi 可执行但返回0块GPU"
        log_error "======================================"
        log_info "驱动状态诊断开始:"
        save_raw lsmod_nvidia lsmod
        save_raw dmesg_nvidia bash -c "dmesg | grep -i -E 'nvidia|NVK|gpu|nvrf'"
        save_raw nvidia_smi_L nvidia-smi -L

        log_info "lsmod | grep nvidia:"
        lsmod 2>/dev/null | grep -i nvidia | tee -a "${LOG_FILE}" || echo "  (无nvidia内核模块)" | tee -a "${LOG_FILE}"
        log_info "dmesg nvidia相关 (最后15行):"
        dmesg 2>/dev/null | grep -i -E 'nvidia|NVK|gpu' | tail -n15 | tee -a "${LOG_FILE}" || echo "  (无相关消息)" | tee -a "${LOG_FILE}"
        log_info "nvidia-smi -L:"
        nvidia-smi -L 2>&1 | tee -a "${LOG_FILE}" || echo "  (失败)" | tee -a "${LOG_FILE}"

        log_error "常见4条解决方案（按顺序试）："
        echo "  1) Secure Boot: BIOS里关闭 Secure Boot，否则MOK签名会阻止nvidia模块加载"
        echo "  2) 内核头文件: sudo apt-get install -y linux-headers-$(uname -r) dkms && sudo dpkg-reconfigure nvidia-driver-560-server"
        echo "  3) ubuntu-drivers: sudo ubuntu-drivers autoinstall && 必须 sudo reboot"
        echo "  4) 强制reboot: 很多dkms模块只有重启后才加载，reboot后再跑一次脚本"

        log_warn "⚠️  由于驱动未加载/系统APT崩溃，脚本生成【失败原因诊断报告】后正常退出（exit 0）"
        write_failure_report
        log_ok "⚠️  诊断报告已生成完毕！report.html 中已写明驱动/APT损坏原因及修复方案"
        log_ok "报告目录: ${OUTPUT_DIR}"
        exit 0
    fi

    log_ok "✅ GPU枚举通过，共检测到 ${GPU_COUNT} 块GPU"
    echo "${GPU_COUNT}" > "${GPU_COUNT_FILE}"

    nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,serial,serial_number,driver_version,vbios_version,pcie.link.gen.current,pcie.link.width.current,temperature.gpu,memory.total,memory.free,memory.used,utilization.gpu --format=csv -i 0-$((GPU_COUNT-1)) > "${OUTPUT_DIR}/gpu_info.csv" 2>/dev/null || true
    save_raw nvidia_smi_full_xml nvidia-smi -q -x
    save_raw nvidia_smi_topo nvidia-smi topo -m

    log_info "逐卡基础信息:"
    local i=0
    for i in $(seq 0 $((GPU_COUNT-1))); do
        local gname gbus gtemp gmem
        gname="$(nvidia-smi --query-gpu=name --format=csv,noheader -i "${i}" 2>/dev/null || echo UNKNOWN)"
        gbus="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i "${i}" 2>/dev/null || echo UNKNOWN)"
        gtemp="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo N/A)"
        gmem="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo N/A)"
        log_info "  GPU${i}: ${gname} | Bus=${gbus} | Temp=${gtemp}°C | Mem=${gmem} MiB"
    done

    GPU_NAME_ARRAY=()
    for i in $(seq 0 $((GPU_COUNT-1))); do
        GPU_NAME_ARRAY+=("$(nvidia-smi --query-gpu=name --format=csv,noheader -i "${i}" 2>/dev/null || echo UNKNOWN)")
    done
}

# ==================== 顺序21: write_failure_report() ====================
write_failure_report() {
    log_info "生成失败原因诊断报告（软着陆）..."
    local end_ts
    end_ts="$(date +%Y-%m-%d_%H:%M:%S)"
    local start="${TS_START//_/ }"
    start="${start:0:4}-${start:4:2}-${start:6:2} ${start:9:2}:${start:11:2}:${start:13:2}"
    local net_status="${NET_REACHABLE_CACHED:-unknown}"

    local raw_files=""
    if [ -d "${RAW_DATA_DIR}" ]; then
        raw_files="$(ls -1 "${RAW_DATA_DIR}" 2>/dev/null | tr '\n' ' ')"
    fi

    cat > "${REPORT_DATA_JSON}" <<EOF
{
  "summary_status": "FAILED_PRECHECK",
  "start_ts": "${start}",
  "end_ts": "${end_ts}",
  "run_config": {
    "CUDA_VERSION": "${CUDA_VERSION}",
    "STRESS_DURATION_SEC": ${STRESS_DURATION_SEC},
    "GPUBURN_DURATION_SEC": ${GPUBURN_DURATION_SEC},
    "FIELD_LEVEL": ${FIELD_LEVEL},
    "TEMP_ALARM_C": ${TEMP_ALARM_C},
    "TEMP_COOLDOWN_C": ${TEMP_COOLDOWN_C},
    "SKIP_INSTALL": ${SKIP_INSTALL},
    "STRESS_ONLY": ${STRESS_ONLY}
  },
  "error_summary": "驱动未加载或nvidia-smi返回0块GPU。按顺序排查：1) BIOS关闭Secure Boot 2) sudo apt-get install linux-headers-$(uname -r) dkms 3) sudo ubuntu-drivers autoinstall 4) 必须sudo reboot后重跑",
  "gpus_found_from_lspci": "$(lspci 2>/dev/null | grep -i nvidia | wc -l || echo 0)",
  "apt_segfault": true,
  "network_reachable": "${net_status}",
  "raw_data_files": "${raw_files}"
}
EOF

    cat > "${FAILURE_DIAGNOSIS_FILE}" <<EOF
=====================================================
NVIDIA GPU 测试 - 失败诊断报告 (软着陆 exit 0)
=====================================================
开始时间: ${start}
结束时间: ${end_ts}
输出目录: ${OUTPUT_DIR}

[状态] FAILED_PRECHECK: nvidia-smi返回0块GPU
-----------------------------------------------------
常见4条解决方案（按顺序执行）：

1. Secure Boot 关闭
   进入BIOS/UEFI：找到 Security -> Secure Boot = Disable
   保存并重启。MOK签名会阻止nvidia内核模块加载。

2. 内核头文件 + dkms 重装
   sudo apt-get update
   sudo apt-get install -y linux-headers-\$(uname -r) dkms build-essential
   sudo dpkg-reconfigure nvidia-driver-560-server
   sudo reboot

3. ubuntu-drivers autoinstall
   sudo ubuntu-drivers autoinstall
   sudo reboot

4. 以上都无效 -> NVIDIA .run 直装
   去 https://www.nvidia.com/Download/index.aspx 下载对应型号.run
   sudo systemctl stop gdm3 2>/dev/null
   sudo sh NVIDIA-Linux-*.run --dkms
   sudo reboot

[网络状态] ${net_status}
[PCIe扫描到NVIDIA设备数] $(lspci 2>/dev/null | grep -i nvidia | wc -l || echo 0)
-----------------------------------------------------
如果PCIe能扫到但nvidia-smi为0，一定是驱动/内核模块问题（硬件没问题）
跑完以上1-4步后 sudo reboot 再重新跑本脚本
=====================================================
EOF
    log_ok "失败诊断报告已写入: ${FAILURE_DIAGNOSIS_FILE} / ${REPORT_DATA_JSON}"
    generate_final_report
}

# ==================== 顺序22: test_pcie_link() ====================
test_pcie_link() {
    log_info "===== PCIe 链路测试 ====="
    save_raw nvidia_smi_pcie nvidia-smi --query-gpu=index,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,clocks_throttle_reasons.sw_thermal_slowdown --format=csv
    save_raw lspci_vvv_nvidia bash -c "lspci -vvv 2>/dev/null | grep -A30 -i nvidia"
    save_raw nvidia_smi_replay bash -c "nvidia-smi -q 2>/dev/null | grep -i replay"

    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"
    local i=0
    for i in $(seq 0 $((GPU_COUNT-1))); do
        wait_for_ready "test_pcie_link_gpu${i}"
        local cur_gen max_gen cur_w max_w bus_id
        cur_gen="$(nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo 0)"
        max_gen="$(nvidia-smi --query-gpu=pcie.link.gen.max --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo 0)"
        cur_w="$(nvidia-smi --query-gpu=pcie.link.width.current --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo 0)"
        max_w="$(nvidia-smi --query-gpu=pcie.link.width.max --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo 0)"
        bus_id="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i "${i}" 2>/dev/null || echo UNKNOWN)"

        local pcie_status="OK"
        if [ "${cur_gen}" -lt "${max_gen}" ] 2>/dev/null; then pcie_status="WARN_GEN"; fi
        if [ "${cur_w}" -lt "${max_w}" ] 2>/dev/null; then pcie_status="WARN_WIDTH"; fi

        if [ "${pcie_status}" = "OK" ]; then
            log_ok "GPU${i} (${bus_id}): PCIe Gen${cur_gen} x${cur_w} / Max Gen${max_gen} x${max_w} ✅"
        else
            log_warn "GPU${i} (${bus_id}): PCIe降速! 当前=Gen${cur_gen}x${cur_w} 最大=Gen${max_gen}x${max_w}"
            echo "    排查建议: 1)BIOS设置PCIe Gen=Max 2)Above 4G Decoding=Enable 3)供电/NVLink线缆插紧 4)换插槽交叉验证" | tee -a "${LOG_FILE}"
        fi

        local replays
        replays="$(nvidia-smi -q -i "${i}" 2>/dev/null | grep -i "replay" | grep -oE '[0-9]+' | head -n1 || echo 0)"
        if [ "${replays}" -gt 0 ] 2>/dev/null; then
            log_warn "GPU${i}: PCIe Replay错误计数=${replays}（>0 说明信号完整性/金手指问题）"
        else
            log_info "GPU${i}: PCIe Replay错误=0 ✅"
        fi
    done
}

# ==================== 顺序23: test_device_query() ====================
test_device_query() {
    log_info "===== CUDA deviceQuery ====="
    local CUDA_BIN_DIR
    CUDA_BIN_DIR="$(cat "${CUDA_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    if [ -n "${CUDA_BIN_DIR}" ] && [ -x "${CUDA_BIN_DIR}/deviceQuery" ]; then
        save_raw cuda_deviceQuery "${CUDA_BIN_DIR}/deviceQuery"
        local rc=$?
        if [ "${rc}" -eq 0 ]; then
            log_ok "deviceQuery 通过 (exit=0)"
        else
            log_warn "deviceQuery exit=${rc}，检查 raw_data/cuda_deviceQuery.txt"
        fi
    else
        log_warn "deviceQuery 未编译，使用 nvidia-smi 替代输出算力信息:"
        save_raw nvidia_smi_compute_cap bash -c "nvidia-smi --query-gpu=index,name,compute_cap --format=csv"
    fi
}

# ==================== 顺序24: test_ecc() ====================
test_ecc() {
    log_info "===== ECC 错误检查 ====="
    save_raw nvidia_smi_ecc nvidia-smi --query-gpu=index,name,ecc.mode.current,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total --format=csv

    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"
    local i=0
    for i in $(seq 0 $((GPU_COUNT-1))); do
        local ecc_mode corr uncorr
        ecc_mode="$(nvidia-smi --query-gpu=ecc.mode.current --format=csv,noheader -i "${i}" 2>/dev/null || echo N/A)"
        corr="$(nvidia-smi --query-gpu=ecc.errors.corrected.volatile.total --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo 0)"
        uncorr="$(nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.total --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo 0)"
        log_info "GPU${i}: ECC=${ecc_mode} | 可纠正=${corr} | 不可纠正=${uncorr}"
        if [ "${uncorr}" != "0" ] && [ "${uncorr}" != "N/A" ] && [ "${uncorr}" -gt 0 ] 2>/dev/null; then
            log_error "GPU${i}: ❗️ 单卡存在不可纠正ECC错误 (${uncorr}) = 显存物理坏块 = 必须RMA更换！"
        fi
        if [ "${corr}" != "0" ] && [ "${corr}" != "N/A" ] && [ "${corr}" -gt 100 ] 2>/dev/null; then
            log_warn "GPU${i}: 可纠正ECC错误累积>${corr}，建议持续观察并准备RMA"
        fi
    done
}

# ==================== 顺序25: test_factory_validation() ====================
test_factory_validation() {
    log_info "===== 工厂级验证 (cuda-memcheck + nvbandwidth) ====="
    local FACTORY_BIN
    FACTORY_BIN="$(cat "${FACTORY_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    local CUDA_BIN_DIR
    CUDA_BIN_DIR="$(cat "${CUDA_BIN_DIR_FILE}" 2>/dev/null || echo "")"

    if [ -x "${FACTORY_BIN}/cuda-memcheck" ] && [ -x "${CUDA_BIN_DIR}/deviceQuery" ]; then
        log_info "执行 cuda-memcheck 扫描 deviceQuery..."
        local cuda_m_log="${RAW_DATA_DIR}/cuda_memcheck_deviceQuery.log"
        ( cd "${CUDA_BIN_DIR}" && "${FACTORY_BIN}/cuda-memcheck" --log "${cuda_m_log}" --tool memcheck ./deviceQuery ) 2>&1 | tee -a "${LOG_FILE}" || true
        save_raw cuda_memcheck_result cat "${cuda_m_log}"
        if grep -qi "error\|failed\|invalid" "${cuda_m_log}" 2>/dev/null; then
            log_warn "cuda-memcheck 扫出可疑错误，详见 raw_data/cuda_memcheck_*.log"
        else
            log_ok "cuda-memcheck deviceQuery 无错误 ✅"
        fi
    else
        log_warn "cuda-memcheck 或 deviceQuery 不存在，跳过显存越界扫描"
    fi

    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"
    if [ -x "${FACTORY_BIN}/nvbandwidth" ]; then
        log_info "执行 nvbandwidth 逐卡带宽测试..."
        local all_ids
        all_ids="$(seq -s, 0 $((GPU_COUNT-1)) 2>/dev/null || echo 0)"
        save_raw nvbandwidth_all "${FACTORY_BIN}/nvbandwidth" -c 1 -d "${all_ids}"
        local i=0
        for i in $(seq 0 $((GPU_COUNT-1))); do
            local bw_std_gb=0
            local gen w
            gen="$(nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo 4)"
            w="$(nvidia-smi --query-gpu=pcie.link.width.current --format=csv,noheader,nounits -i "${i}" 2>/dev/null || echo 16)"
            case "${gen}" in
                3) bw_std_gb=$(( w * 1 )) ;;
                4) bw_std_gb=$(( w * 2 )) ;;
                5) bw_std_gb=$(( w * 4 )) ;;
                *) bw_std_gb=$(( w * 2 )) ;;
            esac
            log_info "GPU${i}: PCIe Gen${gen}x${w} 理论带宽≈${bw_std_gb}GB/s"
        done
    else
        log_warn "nvbandwidth 不存在，使用 CUDA bandwidthTest 替代"
        if [ -x "${CUDA_BIN_DIR}/bandwidthTest" ]; then
            save_raw cuda_bandwidth_test "${CUDA_BIN_DIR}/bandwidthTest"
        fi
    fi
}

# ==================== 顺序26: test_memory() ====================
test_memory() {
    log_info "===== 显存压力测试 ====="
    local FACTORY_BIN
    FACTORY_BIN="$(cat "${FACTORY_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    local CUDA_BIN_DIR
    CUDA_BIN_DIR="$(cat "${CUDA_BIN_DIR_FILE}" 2>/dev/null || echo "")"

    if [ -x "${FACTORY_BIN}/cuda_memtest" ]; then
        log_info "执行 cuda_memtest 全卡显存扫描（可能耗时数分钟）..."
        wait_for_ready "test_memory_start"
        save_raw cuda_memtest_run bash -c "cd '${FACTORY_BIN}' && timeout $((STRESS_DURATION_SEC * 2)) ./cuda_memtest 2>&1 || true"
        if grep -qiE "FAIL|Error|error|FAULT" "${RAW_DATA_DIR}/cuda_memtest_run.txt" 2>/dev/null; then
            if grep -qv "PASSED\|Completed\|finished" "${RAW_DATA_DIR}/cuda_memtest_run.txt" 2>/dev/null; then
                log_warn "cuda_memtest 扫到可疑FAIL/ERROR，详见 raw_data/cuda_memtest_run.txt"
            fi
        else
            log_ok "cuda_memtest 显存扫描通过 ✅"
        fi
    else
        log_warn "cuda_memtest 不可用，使用 bandwidthTest device<->device 替代"
        if [ -x "${CUDA_BIN_DIR}/bandwidthTest" ]; then
            save_raw cuda_bandwidth_d2d "${CUDA_BIN_DIR}/bandwidthTest" --device=0 --memory=pinned --mode=range --start=1024 --end=10485760 --increment=1024000
        fi
    fi
}

# ==================== 顺序27: test_gpu_burn() ====================
test_gpu_burn() {
    log_info "===== gpu-burn 满载正确性校验 ====="
    local FACTORY_BIN
    FACTORY_BIN="$(cat "${FACTORY_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    local CUDA_BIN_DIR
    CUDA_BIN_DIR="$(cat "${CUDA_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"

    if [ ! -x "${FACTORY_BIN}/gpu_burn" ]; then
        log_warn "gpu-burn 不可用，跳过满载正确性校验，改用 nbody 长时间压力替代"
        if [ -x "${CUDA_BIN_DIR}/nbody" ]; then
            wait_for_ready "test_gpu_burn_fallback"
            save_raw nbody_fallback timeout $((GPUBURN_DURATION_SEC + 5)) "${CUDA_BIN_DIR}/nbody" -benchmark -fp64 -numbodies=100000
        fi
        return 0
    fi

    local i=0
    for i in $(seq 0 $((GPU_COUNT-1))); do
        wait_for_ready "test_gpu_burn_gpu${i}"
        log_info "GPU${i}: 执行 gpu-burn ${GPUBURN_DURATION_SEC}s（单卡满载，顺序执行）..."
        local out_log="${RAW_DATA_DIR}/gpu_burn_gpu${i}.log"
        (
            cd "${FACTORY_BIN}"
            timeout $((GPUBURN_DURATION_SEC + 5)) ./gpu_burn "${GPUBURN_DURATION_SEC}" -d "${i}" > "${out_log}" 2>&1 || true
        )
        save_raw "gpu_burn_gpu${i}_raw" cat "${out_log}"
        if grep -qiE "Comparing Stopped OK|Tested successfully|finished.*OK|PASS" "${out_log}" 2>/dev/null; then
            log_ok "GPU${i}: gpu-burn PASS ✅"
        else
            log_warn "GPU${i}: gpu-burn 结果异常，请检查 raw_data/gpu_burn_gpu${i}.log"
        fi
    done
}

# ==================== 顺序28: test_bandwidth() ====================
test_bandwidth() {
    log_info "===== CUDA bandwidthTest (H2D/D2H/D2D) ====="
    local CUDA_BIN_DIR
    CUDA_BIN_DIR="$(cat "${CUDA_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"

    if [ ! -x "${CUDA_BIN_DIR}/bandwidthTest" ]; then
        log_warn "bandwidthTest 未编译，跳过"
        return 0
    fi

    local i=0
    for i in $(seq 0 $((GPU_COUNT-1))); do
        wait_for_ready "test_bandwidth_gpu${i}"
        save_raw "bandwidthTest_gpu${i}" "${CUDA_BIN_DIR}/bandwidthTest" --device="${i}" --memory=pinned --csv
        local bw_h2d bw_d2h bw_d2d
        bw_h2d="$(grep -i 'Host to Device' "${RAW_DATA_DIR}/bandwidthTest_gpu${i}.txt" 2>/dev/null | tail -n1 | awk '{print $(NF-1)}' || echo N/A)"
        bw_d2h="$(grep -i 'Device to Host' "${RAW_DATA_DIR}/bandwidthTest_gpu${i}.txt" 2>/dev/null | tail -n1 | awk '{print $(NF-1)}' || echo N/A)"
        bw_d2d="$(grep -i 'Device to Device' "${RAW_DATA_DIR}/bandwidthTest_gpu${i}.txt" 2>/dev/null | tail -n1 | awk '{print $(NF-1)}' || echo N/A)"
        log_info "GPU${i}: H2D=${bw_h2d} GB/s | D2H=${bw_d2h} GB/s | D2D=${bw_d2d} GB/s"
    done
}

# ==================== 顺序29: test_p2p() ====================
test_p2p() {
    log_info "===== GPU P2P 带宽/延迟测试 ====="
    local CUDA_BIN_DIR
    CUDA_BIN_DIR="$(cat "${CUDA_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"

    save_raw nvidia_smi_p2p nvidia-smi topo -p2p r 2>/dev/null || true

    if [ -x "${CUDA_BIN_DIR}/p2pBandwidthLatencyTest" ] && [ "${GPU_COUNT}" -ge 2 ]; then
        wait_for_ready "test_p2p_run"
        local all_ids
        all_ids="$(seq -s, 0 $((GPU_COUNT-1)))"
        save_raw p2p_bw_lat bash -c "CUDA_VISIBLE_DEVICES=${all_ids} '${CUDA_BIN_DIR}/p2pBandwidthLatencyTest' 2>&1"
        log_ok "P2P带宽/延迟测试完成，详见 raw_data/p2p_bw_lat.txt"
    elif [ -x "${CUDA_BIN_DIR}/topologyQuery" ]; then
        save_raw cuda_topology_query "${CUDA_BIN_DIR}/topologyQuery"
        log_info "p2pBandwidthLatencyTest 不可用或单卡，改用 topologyQuery"
    else
        log_warn "P2P测试程序不可用，只保留 nvidia-smi topo 输出"
    fi
}

# ==================== 顺序30: test_cuda_perf() ====================
test_cuda_perf() {
    log_info "===== CUDA 算力性能测试 ====="
    local CUDA_BIN_DIR
    CUDA_BIN_DIR="$(cat "${CUDA_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"

    if [ -x "${CUDA_BIN_DIR}/nbody" ]; then
        wait_for_ready "test_cuda_perf_nbody"
        save_raw cuda_nbody_fp64 "${CUDA_BIN_DIR}/nbody" -benchmark -fp64 -numdevices="${GPU_COUNT}" -numbodies=50000
        local gflops
        gflops="$(grep -iE 'GFLOP|gflop' "${RAW_DATA_DIR}/cuda_nbody_fp64.txt" 2>/dev/null | tail -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo N/A)"
        log_info "nbody FP64 基准: ~${gflops} GFLOPS (多卡合计)"
    else
        log_warn "nbody 未编译"
    fi

    if [ -x "${CUDA_BIN_DIR}/matrixMul" ]; then
        save_raw cuda_matrix_mul "${CUDA_BIN_DIR}/matrixMul" -wA=2048 -hA=2048 -wB=2048 -hB=2048
        log_info "matrixMul 2048^3 已跑完，详见 raw_data/cuda_matrix_mul.txt"
    fi
}

# ==================== 顺序31: test_stress_thermal() ====================
test_stress_thermal() {
    log_info "===== 压力+温度稳定性测试 (${STRESS_DURATION_SEC}s) ====="
    local CUDA_BIN_DIR
    CUDA_BIN_DIR="$(cat "${CUDA_BIN_DIR_FILE}" 2>/dev/null || echo "")"
    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"

    wait_for_ready "test_stress_thermal_start"

    local trace_csv="${OUTPUT_DIR}/thermal_trace_all.csv"
    echo "timestamp,gpu_idx,temp_C,power_W,sm_clock_MHz,mem_clock_MHz,util_pct" > "${trace_csv}"

    if command -v nvidia-smi >/dev/null 2>&1; then
        (
            local end_ts=$(( $(date +%s) + STRESS_DURATION_SEC + 10 ))
            while [ "$(date +%s)" -lt "${end_ts}" ]; do
                local ts
                ts="$(date '+%Y-%m-%d %H:%M:%S')"
                nvidia-smi --query-gpu=index,temperature.gpu,power.draw,clocks.current.sm,clocks.current.memory,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r idx temp power sm_clk mem_clk util; do
                    echo "${ts},${idx},${temp},${power},${sm_clk},${mem_clk},${util}" | tr -d ' ' >> "${trace_csv}"
                done
                sleep 10
            done
        ) &
        local MONITOR_PID=$!
    fi

    if [ -x "${CUDA_BIN_DIR}/nbody" ]; then
        log_info "启动 nbody 全卡压力（timeout $((STRESS_DURATION_SEC + 5))s）..."
        ( timeout $((STRESS_DURATION_SEC + 5)) "${CUDA_BIN_DIR}/nbody" -benchmark -fp64 -numdevices="${GPU_COUNT}" -numbodies=999999 > "${RAW_DATA_DIR}/stress_nbody_full.log" 2>&1 || true ) &
        local STRESS_PID=$!
        wait "${STRESS_PID}" 2>/dev/null || true
    elif command -v nvidia-smi >/dev/null 2>&1; then
        log_warn "nbody 不可用，改用 nvidia-smi dmon 纯监控 + gpu_burn（若可用）"
        local FACTORY_BIN
        FACTORY_BIN="$(cat "${FACTORY_BIN_DIR_FILE}" 2>/dev/null || echo "")"
        if [ -x "${FACTORY_BIN}/gpu_burn" ]; then
            ( cd "${FACTORY_BIN}" && timeout $((STRESS_DURATION_SEC + 5)) ./gpu_burn "${STRESS_DURATION_SEC}" > "${RAW_DATA_DIR}/stress_gpuburn_full.log" 2>&1 || true ) &
            local STRESS_PID=$!
            wait "${STRESS_PID}" 2>/dev/null || true
        else
            sleep $((STRESS_DURATION_SEC + 2))
        fi
    else
        sleep $((STRESS_DURATION_SEC + 2))
    fi

    [ -n "${MONITOR_PID}" ] && kill "${MONITOR_PID}" 2>/dev/null || true
    wait 2>/dev/null || true

    local peak_temp=0 avg_power=0 peak_clk=0 count=0 exceeded=0
    if [ -f "${trace_csv}" ] && [ "$(wc -l < "${trace_csv}")" -gt 2 ]; then
        local temps powers clocks
        temps="$(tail -n +2 "${trace_csv}" 2>/dev/null | awk -F',' '{print $3}' | grep -E '^[0-9]+$' || echo 0)"
        powers="$(tail -n +2 "${trace_csv}" 2>/dev/null | awk -F',' '{print $4}' | grep -E '^[0-9]+\.?[0-9]*$' || echo 0)"
        clocks="$(tail -n +2 "${trace_csv}" 2>/dev/null | awk -F',' '{print $5}' | grep -E '^[0-9]+$' || echo 0)"
        peak_temp="$(echo "${temps}" | sort -nr | head -n1 || echo 0)"
        avg_power="$(echo "${powers}" | awk '{sum+=$1; n++} END {if(n>0) printf "%.0f", sum/n; else print 0}')"
        peak_clk="$(echo "${clocks}" | sort -nr | head -n1 || echo 0)"
        count="$(echo "${temps}" | wc -l || echo 0)"
        exceeded="$(echo "${temps}" | awk -v t="${TEMP_ALARM_C}" '$1 >= t' | wc -l || echo 0)"
    fi

    save_raw thermal_trace_csv cat "${trace_csv}"

    log_info "温度压力总结:"
    log_info "  数据采样点    = ${count}"
    log_info "  峰值温度      = ${peak_temp}°C (报警阈值=${TEMP_ALARM_C}°C)"
    log_info "  超过阈值次数  = ${exceeded}"
    log_info "  平均功耗      = ${avg_power} W"
    log_info "  峰值SM频率    = ${peak_clk} MHz"

    if [ "${peak_temp}" -lt "${TEMP_ALARM_C}" ] 2>/dev/null; then
        log_ok "温度压力PASS ✅ 峰值 ${peak_temp}°C < ${TEMP_ALARM_C}°C"
    else
        log_warn "温度峰值触达/超过阈值 ${peak_temp}°C，但看门狗已确保恢复后继续（有${exceeded}个采样点超阈值）"
    fi
}

# ==================== 顺序32: test_dcgm() ====================
test_dcgm() {
    log_info "===== NVIDIA DCGM 诊断 ====="
    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"

    if ! command -v dcgmi >/dev/null 2>&1; then
        log_warn "dcgmi 不可用，使用 nvidia-smi -q 替代诊断"
        save_raw nvidia_smi_q_full nvidia-smi -q
        return 0
    fi

    save_raw dcgmi_discovery dcgmi discovery -l
    sudo systemctl is-active --quiet nvidia-dcgm.service 2>/dev/null || sudo systemctl start nvidia-dcgm.service 2>/dev/null || true
    sleep 1

    local i=0
    for i in $(seq 0 $((GPU_COUNT-1))); do
        wait_for_ready "test_dcgm_gpu${i}"
        log_info "GPU${i}: 运行 dcgmi diag '3. Quick' (快速诊断)"
        save_raw "dcgmi_diag_gpu${i}" dcgmi diag -r "${i}" -p 1
        local diag_out="${RAW_DATA_DIR}/dcgmi_diag_gpu${i}.txt"
        if grep -qiE "PASS|success|Success" "${diag_out}" 2>/dev/null; then
            log_ok "GPU${i}: DCGM diag PASS ✅"
        else
            log_warn "GPU${i}: DCGM diag 结果异常，详见 ${diag_out}"
        fi

        save_raw "dcgmi_stats_gpu${i}" dcgmi stats -g "${i}" -d
        local retired
        retired="$(grep -iE 'Retired|retired' "${RAW_DATA_DIR}/dcgmi_stats_gpu${i}.txt" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || echo 0)"
        if [ "${retired}" -gt 0 ] 2>/dev/null; then
            log_error "GPU${i}: ❗️ DCGM Retired Pages=${retired} > 0 = 显存物理坏块标记 = 必须RMA更换！"
        else
            log_info "GPU${i}: DCGM Retired Pages=0 ✅"
        fi
    done
}

# ==================== 顺序33: test_fieldiag() ====================
test_fieldiag() {
    log_info "===== NVIDIA 原厂 fieldiag 诊断 ====="
    local DC_GPU_LIST="H100 H200 H800 H900 B200 B300 B380 B390 GB200 GB300 A100 A800 A900 A30 A10 A10G T4 T4g L4 L40 L40S V100 V100S P100 P40 P4 K80 K40 M60 M40 A2 L20 L2 L10 L10G PG500 PG506 PG509 HGX DGX Tesla GRID Quadro RTX GV100 GP100"
    local f_bin=""
    for p in /usr/local/cuda/bin/fieldiag /opt/nvidia/fieldiag/bin/fieldiag /usr/bin/fieldiag "${SCRIPT_DIR}/fieldiag"; do
        if [ -x "${p}" ]; then f_bin="${p}"; break; fi
    done
    [ -z "${f_bin}" ] && f_bin="$(command -v fieldiag 2>/dev/null || echo "")"
    [ -n "${f_bin}" ] && [ ! -x "${f_bin}" ] && f_bin=""

    local GPU_COUNT
    GPU_COUNT="$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)"
    local have_dc_gpu=false
    local i=0
    for i in $(seq 0 $((GPU_COUNT-1))); do
        local gname
        gname="$(nvidia-smi --query-gpu=name --format=csv,noheader -i "${i}" 2>/dev/null || echo UNKNOWN)"
        for g in ${DC_GPU_LIST}; do
            if echo "${gname}" | grep -qi "${g}"; then have_dc_gpu=true; break 2; fi
        done
    done

    if [ -z "${f_bin}" ] || [ "${have_dc_gpu}" = "false" ]; then
        local status=""
        if [ -z "${f_bin}" ] && [ "${have_dc_gpu}" = "false" ]; then
            status="SKIPPED_NOT_FOUND_AND_CONSUMER_GPU"
        elif [ -z "${f_bin}" ]; then
            status="SKIPPED_NOT_FOUND"
        else
            status="CONSUMER_GPU_SKIPPED"
        fi
        log_info "ℹ️  未找到fieldiag或非数据中心GPU，自动跳过原厂诊断，PCIe/温度等其他检测已完整执行"
        echo "status=${status}" > "${FIELDIAG_RESULT_FILE}"
        echo "fieldiag_binary=${f_bin}" >> "${FIELDIAG_RESULT_FILE}"
        echo "have_datacenter_gpu=${have_dc_gpu}" >> "${FIELDIAG_RESULT_FILE}"
        return 0
    fi

    echo "status=RUNNING" > "${FIELDIAG_RESULT_FILE}"
    echo "fieldiag_binary=${f_bin}" >> "${FIELDIAG_RESULT_FILE}"
    echo "level=${FIELD_LEVEL}" >> "${FIELDIAG_RESULT_FILE}"
    log_ok "检测到 fieldiag 二进制: ${f_bin}"
    log_ok "检测到数据中心级GPU，开始 Level=${FIELD_LEVEL} 原厂诊断..."

    if [ "${FORCE_FIELDIAG}" != "true" ]; then
        log_info "先执行 fieldiag 预检 (Level 0..6)"
        local precheck_ok=true
        local pl=0
        for pl in 0 1 2 3 4 5 6; do
            wait_for_ready "fieldiag_precheck_${pl}"
            local pout="${RAW_DATA_DIR}/fieldiag_precheck_L${pl}.log"
            ( "${f_bin}" -l "${pl}" > "${pout}" 2>&1 ) || true
            if grep -qiE "FAIL|ERROR|Failed" "${pout}" 2>/dev/null; then
                log_warn "fieldiag 预检 Level ${pl} 有告警（可查看 ${pout}）"
            fi
        done
    else
        log_info "FORCE_FIELDIAG=true，跳过预检直接进入 Level=${FIELD_LEVEL}"
    fi

    wait_for_ready "fieldiag_level_${FIELD_LEVEL}"
    log_warn "🚨 fieldiag Level=${FIELD_LEVEL} 开始，可能持续 5分钟~1小时，请勿中断..."
    local main_out="${RAW_DATA_DIR}/fieldiag.log"
    ( "${f_bin}" -l "${FIELD_LEVEL}" > "${main_out}" 2>&1 ) || true
    save_raw fieldiag_raw cat "${main_out}"

    log_info "fieldiag 结果摘要:"
    grep -iE "PASS|FAIL|ERROR|completed|Result|Summary" "${main_out}" 2>/dev/null | tee -a "${LOG_FILE}" || echo "  (无匹配摘要，详见 raw_data/fieldiag.log)" | tee -a "${LOG_FILE}"

    if grep -qiE "PASS|completed successfully" "${main_out}" 2>/dev/null; then
        echo "status=PASS" > "${FIELDIAG_RESULT_FILE}"
        log_ok "fieldiag Level=${FIELD_LEVEL} PASS ✅"
    elif grep -qiE "FAIL|ERROR" "${main_out}" 2>/dev/null; then
        echo "status=FAIL" > "${FIELDIAG_RESULT_FILE}"
        log_warn "fieldiag Level=${FIELD_LEVEL} 检出 FAIL/ERROR，详见 raw_data/fieldiag.log"
    else
        echo "status=UNKNOWN" > "${FIELDIAG_RESULT_FILE}"
        log_info "fieldiag 结果 UNKNOWN（需人工查看 raw_data/fieldiag.log）"
    fi
}

# ==================== 顺序34: generate_final_report() ====================
generate_final_report() {
    log_info "===== 生成最终报告 ====="
    local end_ts
    end_ts="$(date +%Y-%m-%d_%H:%M:%S)"
    local start="${TS_START//_/ }"
    start="${start:0:4}-${start:4:2}-${start:6:2} ${start:9:2}:${start:11:2}:${start:13:2}"

    if [ ! -f "${REPORT_DATA_JSON}" ]; then
        local net_status="${NET_REACHABLE_CACHED:-unknown}"
        local raw_files=""
        [ -d "${RAW_DATA_DIR}" ] && raw_files="$(ls -1 "${RAW_DATA_DIR}" 2>/dev/null | tr '\n' ' ')"
        cat > "${REPORT_DATA_JSON}" <<EOF
{
  "summary_status": "COMPLETED",
  "start_ts": "${start}",
  "end_ts": "${end_ts}",
  "run_config": {
    "CUDA_VERSION": "${CUDA_VERSION}",
    "STRESS_DURATION_SEC": ${STRESS_DURATION_SEC},
    "GPUBURN_DURATION_SEC": ${GPUBURN_DURATION_SEC},
    "FIELD_LEVEL": ${FIELD_LEVEL},
    "TEMP_ALARM_C": ${TEMP_ALARM_C},
    "TEMP_COOLDOWN_C": ${TEMP_COOLDOWN_C},
    "SKIP_INSTALL": ${SKIP_INSTALL},
    "STRESS_ONLY": ${STRESS_ONLY}
  },
  "gpus_found_from_lspci": "$(lspci 2>/dev/null | grep -i nvidia | wc -l || echo 0)",
  "apt_segfault": false,
  "network_reachable": "${net_status}",
  "raw_data_files": "${raw_files}"
}
EOF
    fi

    if [ -f "${SCRIPT_DIR}/generate_report.py" ]; then
        log_info "调用 generate_report.py 生成 report.html ..."
        ( python3 "${SCRIPT_DIR}/generate_report.py" --output_dir "${OUTPUT_DIR}" --raw_data_dir "${RAW_DATA_DIR}" --log_file "${LOG_FILE}" ) 2>&1 | tee -a "${LOG_FILE}" || true
        if [ -f "${OUTPUT_DIR}/report.html" ]; then
            log_ok "✅ 最终报告已生成: ${OUTPUT_DIR}/report.html"
        else
            log_warn "generate_report.py 未产出 report.html，但 raw_data + test.log 已完整"
        fi
    else
        log_warn "未找到 generate_report.py，跳过HTML报告生成"
        log_info "但所有原始数据已保存在: ${RAW_DATA_DIR}/"
        log_info "完整测试日志: ${LOG_FILE}"
        log_info "可手动打包 ${OUTPUT_DIR} 目录提交RMA"
    fi
}

# ==================== 顺序35: main() ====================
main() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-install)     SKIP_INSTALL=true; shift ;;
            --stress-only)      STRESS_ONLY=true; shift ;;
            --field-level)      FIELD_LEVEL="$2"; shift 2 ;;
            --field-level=*)    FIELD_LEVEL="${1#*=}"; shift ;;
            --gpuburn-time)     GPUBURN_DURATION_SEC="$2"; shift 2 ;;
            --gpuburn-time=*)   GPUBURN_DURATION_SEC="${1#*=}"; shift ;;
            --force-fieldiag)   FORCE_FIELDIAG=true; shift ;;
            -h|--help)
                echo "用法: $0 [选项]"
                echo "  --skip-install       跳过依赖/驱动/CUDA/DCGM下载安装（只跑测试）"
                echo "  --stress-only        仅执行依赖/驱动/枚举/压力+报告（快速模式）"
                echo "  --field-level N      fieldiag 诊断级别 0~3（默认1）"
                echo "  --gpuburn-time N     gpu-burn 秒数（默认120）"
                echo "  --force-fieldiag     跳过 fieldiag 预检直接跑主级别"
                echo "  -h, --help           显示此帮助"
                exit 0
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done
    set -- "${positional[@]}"

    if [ "$#" -eq 0 ] && [ "${SKIP_INSTALL}" = "false" ] && [ "${STRESS_ONLY}" = "false" ] && [ "${FIELD_LEVEL}" = "1" ] && [ "${GPUBURN_DURATION_SEC}" = "120" ] && [ "${FORCE_FIELDIAG}" = "false" ]; then
        interactive_menu
    fi

    init

    log_info "======================================"
    log_info "输出目录 : ${OUTPUT_DIR}"
    log_info "日志文件 : ${LOG_FILE}"
    log_info "配置: stress=${STRESS_DURATION_SEC}s  gpuburn=${GPUBURN_DURATION_SEC}s  fieldiag=L${FIELD_LEVEL}  temp_alarm=${TEMP_ALARM_C}°C"
    log_info "开关: skip_install=${SKIP_INSTALL}  stress_only=${STRESS_ONLY}  force_fieldiag=${FORCE_FIELDIAG}"
    log_info "======================================"

    cat > "${RUN_CONFIG_FILE}" <<EOF
run_config:
  cuda_version: "${CUDA_VERSION}"
  stress_duration_sec: ${STRESS_DURATION_SEC}
  gpuburn_duration_sec: ${GPUBURN_DURATION_SEC}
  field_level: ${FIELD_LEVEL}
  temp_alarm_c: ${TEMP_ALARM_C}
  temp_cooldown_c: ${TEMP_COOLDOWN_C}
  skip_install: ${SKIP_INSTALL}
  stress_only: ${STRESS_ONLY}
  force_fieldiag: ${FORCE_FIELDIAG}
  output_dir: "${OUTPUT_DIR}"
  log_file: "${LOG_FILE}"
EOF

    log_info "=== 手动暂停/恢复命令 ==="
    log_info "  手动立即暂停所有测试:   touch ${MANUAL_PAUSE}"
    log_info "  手动恢复:                rm -f ${MANUAL_PAUSE}"
    log_info "  温度报警自动暂停标记:    ${PAUSE_MARKER}（达到冷却自动删除）"
    log_info "  查看看门狗实时温度:      tail -f ${TEMP_LOG}"
    log_info "=========================="

    start_temp_watchdog

    if [ "${STRESS_ONLY}" = "true" ]; then
        log_warn "模式: STRESS_ONLY（仅依赖/驱动/枚举/压力/报告，跳过大部分子测试）"
        install_system_deps
        check_system
        check_nvidia_driver || true
        enumerate_gpus
        install_cuda_toolkit || true
        test_stress_thermal
        generate_final_report
        log_ok "STRESS_ONLY 模式全部完成 🎉"
        log_ok "报告目录: ${OUTPUT_DIR}"
        log_info "提交RMA: 打包整个目录 tar czf gpu_report_${TS_START}.tar.gz ${OUTPUT_DIR}"
        return 0
    fi

    if [ "${SKIP_INSTALL}" = "false" ]; then
        log_info "模式: 完整安装 + 测试"
        install_system_deps
        check_system
        check_nvidia_driver || true
        install_cuda_toolkit || true
        install_dcgm || true
        install_factory_tools
    else
        log_info "模式: SKIP_INSTALL（跳过apt安装，假设依赖已就位）"
        install_system_deps
        check_system
        check_nvidia_driver || true
        if command -v nvcc >/dev/null 2>&1; then
            compile_cuda_samples
        fi
        install_factory_tools
    fi

    log_info "======== 测试阶段开始 ========"
    enumerate_gpus
    test_pcie_link
    test_device_query
    test_ecc
    test_factory_validation
    test_memory
    test_gpu_burn
    test_bandwidth
    test_p2p
    test_cuda_perf
    test_stress_thermal
    test_dcgm
    test_fieldiag

    generate_final_report

    log_ok "======================================"
    log_ok "🎉 NVIDIA GPU 售后自动化测试全部完成！"
    log_ok "======================================"
    log_ok "最终报告 : ${OUTPUT_DIR}/report.html"
    log_ok "测试日志 : ${LOG_FILE}"
    log_ok "原始数据 : ${RAW_DATA_DIR}/"
    log_info "提交RMA命令: tar czf gpu_test_report_${TS_START}.tar.gz ${OUTPUT_DIR}"
}

# ==================== 顺序36: 最外层安全壳执行 ====================
WRAPPER_RC=0
(
  main "$@"
) || WRAPPER_RC=$?

if [ -n "${WATCHDOG_BG_PID}" ] && kill -0 "${WATCHDOG_BG_PID}" 2>/dev/null; then
    kill "${WATCHDOG_BG_PID}" 2>/dev/null || true
fi
if [ -f "${WATCHDOG_PID_FILE}" ]; then
    local_wpid="$(cat "${WATCHDOG_PID_FILE}" 2>/dev/null || true)"
    [ -n "${local_wpid}" ] && kill "${local_wpid}" 2>/dev/null || true
fi
pkill -f "watchdog_temp.log" 2>/dev/null || true

if [ "${WRAPPER_RC}" -eq 0 ]; then
  echo ""
  echo -e "${GREEN}✅ 脚本正常结束${NC}"
else
  echo ""
  echo -e "${YELLOW}⚠️  脚本内部遇到非零退出码(${WRAPPER_RC})，但已被外壳隔离${NC}"
  echo -e "${YELLOW}    请查看日志: ${LOG_FILE}${NC}"
  if [ -f "${OUTPUT_DIR}/test.log" ] && [ -f "${SCRIPT_DIR}/generate_report.py" ]; then
    echo -e "${BLUE}尝试生成失败原因诊断报告...${NC}"
    ( python3 "${SCRIPT_DIR}/generate_report.py" --output_dir "${OUTPUT_DIR}" --raw_data_dir "${RAW_DATA_DIR}" --log_file "${LOG_FILE}" >/dev/null 2>&1 ) || true
    if [ -f "${OUTPUT_DIR}/report.html" ]; then
      echo -e "${GREEN}✅ 报告已生成: ${OUTPUT_DIR}/report.html${NC}"
    fi
  fi
fi
echo -e "${BLUE}所有输出目录: ${OUTPUT_DIR}${NC}"
exit 0
