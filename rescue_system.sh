#!/usr/bin/env bash
# ============================================================
#  rescue_system.sh  —  系统救援脚本
#  用途：把被 GPU 测试脚本搞坏的 APT/initrd/dpkg 锁/内核包恢复到可用状态
#  安全原则：
#    1. 不主动 reboot
#    2. 不在正常启动模式下调用 update-initramfs
#    3. 不做跨版本 dist-upgrade / full-upgrade
#    4. 所有操作日志写入 /var/log/rescue_system.log
# 用法：
#    方式 A（推荐）：GRUB → recovery mode → root shell 里执行
#         bash rescue_system.sh --recovery
#    方式 B：如果已经能正常进桌面，普通用户也能跑（会自动 sudo）
#         bash rescue_system.sh
# ============================================================
set +e
LOG_FILE="/var/log/rescue_system_$(date +%Y%m%d_%H%M%S).log"
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] $*" | tee -a "${LOG_FILE}"
}

SUDO=""
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

IN_RECOVERY=false
if [ -f /proc/cmdline ] && grep -q 'recovery' /proc/cmdline 2>/dev/null; then
    IN_RECOVERY=true
fi
if [ "${1}" = "--recovery" ]; then
    IN_RECOVERY=true
fi

log "=============================================="
log " Rescue System Script  v1.0"
log " 当前模式: $([ "${IN_RECOVERY}" = "true" ] && echo "RECOVERY MODE (安全)" || echo "NORMAL MODE (不重建initrd)")"
log " 日志: ${LOG_FILE}"
log "=============================================="

log_info()  { log "[INFO]   $*"; }
log_ok()    { log "[OK]     $*"; }
log_warn()  { log "[WARN]   $*"; }
log_err()   { log "[ERROR]  $*"; }

# ============================================================
# Step 0: 清理所有 APT/dpkg 锁（最常见卡死原因）
# ============================================================
step0_clear_locks() {
    log_info "Step 0: 清理所有 APT/dpkg 锁文件..."
    ${SUDO} rm -f /var/lib/apt/lists/lock 2>/dev/null
    ${SUDO} rm -f /var/cache/apt/archives/lock 2>/dev/null
    ${SUDO} rm -f /var/lib/dpkg/lock-frontend 2>/dev/null
    ${SUDO} rm -f /var/lib/dpkg/lock 2>/dev/null
    ${SUDO} rm -f /var/cache/debconf/config.dat.lock 2>/dev/null
    log_ok "APT/dpkg 锁已清理"
}

# ============================================================
# Step 1: 恢复 dpkg 中断的配置（dpkg --configure -a）
# ============================================================
step1_dpkg_configure() {
    log_info "Step 1: 修复 dpkg 中断的包配置..."
    local rc=0
    ${SUDO} dpkg --configure -a --force-confdef --force-confold 2>&1 | tee -a "${LOG_FILE}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        log_warn "dpkg --configure -a 返回非 0，继续尝试 apt-get -f install"
    else
        log_ok "dpkg 配置恢复成功"
    fi
    ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -f -y --fix-broken 2>&1 | tee -a "${LOG_FILE}" || true
}

# ============================================================
# Step 2: 清理 GPU 测试脚本写入的危险 APT 源
# ============================================================
step2_remove_dangerous_sources() {
    log_info "Step 2: 清理 GPU 测试脚本添加的危险 APT 源..."
    local dangerous_patterns=(
        "cuda-keyring"
        "gpu_test_dcgm"
        "nvidia-cuda"
        "nobleoper.download"
        "developer.download.nvidia.com.*cuda.*repos"
    )
    ${SUDO} rm -f /etc/apt/sources.list.d/cuda-keyring.list 2>/dev/null || true
    ${SUDO} rm -f /etc/apt/sources.list.d/gpu_test_dcgm.list 2>/dev/null || true
    ${SUDO} rm -f /etc/apt/sources.list.d/nvidia-cuda.list 2>/dev/null || true
    ${SUDO} rm -f /etc/apt/sources.list.d/nvidia-dcgm.list 2>/dev/null || true
    ${SUDO} rm -f /etc/apt/sources.list.d/gpu_test_sources.list 2>/dev/null || true
    # 清理所有 .sources 文件里带 nobleoper 的坏条目
    if ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1; then
        for f in /etc/apt/sources.list.d/*.sources; do
            ${SUDO} sed -i '/nobleoper/d' "${f}" 2>/dev/null || true
        done
    fi
    log_ok "危险源已清理"
}

# ============================================================
# Step 3: 把 /etc/apt/sources.list 重建为干净的 noble 源
#         （先备份，再重建，不覆盖第三方 PPA）
# ============================================================
step3_rebuild_sources_list() {
    log_info "Step 3: 重建 /etc/apt/sources.list 为干净的 noble 源..."
    local bak="/etc/apt/sources.list.rescue_bak_$(date +%Y%m%d_%H%M%S)"
    [ -f /etc/apt/sources.list ] && ${SUDO} cp -a /etc/apt/sources.list "${bak}" 2>/dev/null
    local tsinghua_ok=true
    if ! (echo > /dev/tcp/mirrors.tuna.tsinghua.edu.cn/443) 2>/dev/null; then
        tsinghua_ok=false
    fi
    if [ "${tsinghua_ok}" = "true" ]; then
        log_info "使用清华源..."
        ${SUDO} tee /etc/apt/sources.list >/dev/null <<'APT_EOF'
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
APT_EOF
    else
        log_info "海外网络，使用官方 archive.ubuntu.com..."
        ${SUDO} tee /etc/apt/sources.list >/dev/null <<'APT_EOF'
deb http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
APT_EOF
    fi
    log_ok "sources.list 已重建（备份在 ${bak}）"
}

# ============================================================
# Step 4: 清 APT 缓存 + 重建包索引
# ============================================================
step4_apt_update() {
    log_info "Step 4: 清缓存 + apt update..."
    ${SUDO} rm -rf /var/lib/apt/lists/* 2>/dev/null
    ${SUDO} mkdir -p /var/lib/apt/lists/partial 2>/dev/null
    local rc=0
    ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get update --fix-missing --allow-releaseinfo-change -o Acquire::Retries=3 2>&1 | tee -a "${LOG_FILE}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        log_warn "apt update 还有错误，再来一次 dpkg --configure + -f install + update"
        ${SUDO} dpkg --configure -a --force-confdef --force-confold 2>&1 | tee -a "${LOG_FILE}" || true
        ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -f -y --fix-broken 2>&1 | tee -a "${LOG_FILE}" || true
        ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get update --fix-missing 2>&1 | tee -a "${LOG_FILE}" || rc=$?
    fi
    if [ "${rc}" -eq 0 ]; then
        log_ok "APT 源已恢复正常"
    else
        log_err "APT 源仍有问题，但救援继续"
    fi
    return 0
}

# ============================================================
# Step 5: 修复内核包（从半成品恢复到完整）
#         ★ 安全：只修当前运行内核，不搞其他版本
# ============================================================
step5_fix_kernel() {
    log_info "Step 5: 修复当前运行内核的包完整性..."
    local kver
    kver="$(uname -r)"
    log_info "  当前内核: ${kver}"

    # 5.1 修复 linux-image / linux-headers 包
    ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y \
        --no-install-recommends \
        "linux-image-${kver}" "linux-headers-${kver}" 2>&1 | tee -a "${LOG_FILE}" || true

    # 5.2 检查 /boot 下的文件
    if [ -f "/boot/vmlinuz-${kver}" ]; then
        local sz
        sz="$(${SUDO} stat -c%s "/boot/vmlinuz-${kver}" 2>/dev/null || echo 0)"
        log_info "  vmlinuz: /boot/vmlinuz-${kver} (${sz} bytes)"
    else
        log_warn "  ⚠️  vmlinuz-${kver} 不存在！"
    fi
    if [ -f "/boot/initrd.img-${kver}" ]; then
        local isz
        isz="$(${SUDO} stat -c%s "/boot/initrd.img-${kver}" 2>/dev/null || echo 0)"
        log_info "  initrd:  /boot/initrd.img-${kver} (${isz} bytes)"
        if [ "${isz}" -lt 31457280 ]; then
            log_warn "  ⚠️  initrd 小于 30MB，可能不完整"
            if [ "${IN_RECOVERY}" = "true" ]; then
                log_info "  （在 recovery 模式下重建 initrd）"
                ${SUDO} update-initramfs -u -k "${kver}" 2>&1 | tee -a "${LOG_FILE}" || true
            else
                log_warn "  不在 recovery 模式，跳过重建。下次启动进入 recovery 再执行：bash rescue_system.sh --recovery"
            fi
        fi
    else
        log_warn "  ⚠️  initrd.img-${kver} 不存在！"
        if [ "${IN_RECOVERY}" = "true" ]; then
            log_info "  （在 recovery 模式下新建 initrd）"
            ${SUDO} update-initramfs -c -k "${kver}" 2>&1 | tee -a "${LOG_FILE}" || true
        else
            log_warn "  不在 recovery 模式，跳过重建。重启进入 recovery 后再执行：bash rescue_system.sh --recovery"
        fi
    fi
    log_ok "内核包检查完成"
}

# ============================================================
# Step 6: 修复关键基础包（dpkg-dev/bzip2/gcc 等断裂依赖）
#         ★ 安全：用 --fix-missing 逐个装，不做 full-upgrade
# ============================================================
step6_fix_base_packages() {
    log_info "Step 6: 修复基础依赖包（bzip2/dpkg-dev/build-essential/g++）..."
    local pkgs=(bzip2 gzip tar xz-utils dpkg dpkg-dev libc6 libstdc++6 coreutils binutils make)
    local p
    for p in "${pkgs[@]}"; do
        ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends --fix-missing --allow-downgrades "${p}" 2>&1 | tee -a "${LOG_FILE}" || true
    done
    # g++ / gcc 可能版本冲突，单独处理
    ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends --fix-missing --allow-downgrades g++ gcc libc6-dev 2>&1 | tee -a "${LOG_FILE}" || true
    # 最后 -f install 收尾
    ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -f -y --fix-broken 2>&1 | tee -a "${LOG_FILE}" || true
    if command -v g++ >/dev/null 2>&1; then
        log_ok "✅ g++ 可用: $(g++ --version | head -n1)"
    else
        log_warn "⚠️  g++ 仍不可用，GPU-Burn 等需要编译的工具后续会被跳过"
    fi
}

# ============================================================
# Step 7: 恢复 /etc/modprobe.d/blacklist-nouveau.conf
#         （脚本之前可能写过也可能没写，安全起见写一份，但不重建 initrd）
# ============================================================
step7_nouveau_blacklist() {
    log_info "Step 7: 确保 nouveau 黑名单配置存在..."
    ${SUDO} tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    log_ok "blacklist-nouveau.conf 已就位"
    log_warn "  注意：黑名单只是文本配置，要生效必须满足其一："
    log_warn "    a) 在 recovery 模式下执行 update-initramfs 重建 initrd"
    log_warn "    b) 或者使用 nouveau unbind + modprobe nvidia 动态切换驱动（推荐，无需重启）"
}

# ============================================================
# Step 8: 检查是否能正常加载 nvidia 驱动（动态方式，无需重启）
# ============================================================
step8_test_nvidia_load() {
    log_info "Step 8: 尝试动态加载 NVIDIA 驱动（无需重启）..."
    # 如果 nvidia 模块已经加载，说明已经 OK
    if lsmod 2>/dev/null | grep -q '^nvidia'; then
        log_ok "✅ nvidia 内核模块已加载"
        if command -v nvidia-smi >/dev/null 2>&1; then
            log_ok "✅ nvidia-smi 可用"
            ${SUDO} nvidia-smi -L 2>&1 | tee -a "${LOG_FILE}" || true
        else
            log_warn "nvidia 模块加载了但 nvidia-smi 命令不在 PATH"
        fi
        return 0
    fi

    # 尝试 modprobe（如果模块已编译好就直接加载）
    if command -v modprobe >/dev/null 2>&1; then
        ${SUDO} modprobe nvidia nvidia_modeset nvidia_uvm nvidia_drm 2>&1 | tee -a "${LOG_FILE}" || true
        sleep 2
        if lsmod 2>/dev/null | grep -q '^nvidia'; then
            log_ok "✅ nvidia 模块通过 modprobe 加载成功"
            return 0
        fi
    fi

    log_warn "nvidia 模块无法动态加载，需要重启才能生效。"
    log_info "  （救援脚本不会主动重启。请在 recovery 模式下重建 initrd 后再 reboot）"
}

# ============================================================
# Step 9: 汇总
# ============================================================
step9_summary() {
    log ""
    log "=============================================="
    log " 救援完成汇总"
    log "=============================================="
    log ""
    log "  ✅ dpkg/APT 锁:    已清理"
    log "  ✅ APT 源:          已重建为 noble"
    log "  ✅ 基础包:          已尝试修复"
    log "  ℹ️  initrd 重建:    $([ "${IN_RECOVERY}" = "true" ] && echo "已执行" || echo "未执行（需 recovery 模式）")"
    log "  ℹ️  nvidia 加载:    $([ "$(lsmod 2>/dev/null | grep -c '^nvidia')" -gt 0 ] && echo "OK" || echo "需重启生效")"
    log ""
    log " 📋 后续步骤："
    log "   1) 如果是在 recovery 模式下跑的："
    log "      直接 reboot 即可，进系统后 nvidia-smi 应该能用"
    log ""
    log "   2) 如果是在正常系统里跑的："
    log "      a) 正常关机/重启（不要强制），让系统用当前 initrd 启动"
    log "      b) 进系统后执行 nvidia-smi 确认驱动状态"
    log "      c) 如果 nvidia 还是不工作，进 GRUB → recovery mode → 再跑一次："
    log "         bash rescue_system.sh --recovery"
    log ""
    log "   3) GPU 测试脚本执行前请先跑这个救援脚本！"
    log "=============================================="
    log_ok "救援脚本执行完毕。日志: ${LOG_FILE}"
}

# ============================================================
# 主流程
# ============================================================
main() {
    step0_clear_locks
    step1_dpkg_configure
    step2_remove_dangerous_sources
    step3_rebuild_sources_list
    step4_apt_update
    step5_fix_kernel
    step6_fix_base_packages
    step7_nouveau_blacklist
    step8_test_nvidia_load
    step9_summary
}

main "$@"