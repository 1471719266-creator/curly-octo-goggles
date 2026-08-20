#!/bin/bash
set +e

LOG="/workspace/fix_gui_$(date +%Y%m%d_%H%M%S).log"

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }
log_info()  { log "[INFO] $*"; }
log_ok()    { log "[OK]   $*"; }
log_warn()  { log "[WARN] $*"; }
log_error() { log "[ERR]  $*"; }

log "============================================"
log " Ubuntu 图形界面恢复 + GRUB 修复脚本"
log " 日志: ${LOG}"
log "============================================"

if [ "$(id -u)" -ne 0 ]; then
    log "需要 root 权限，正在 sudo..."
    exec sudo bash "$0" "$@"
fi

log_info "[1/9] 清理 APT/dpkg 锁..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/debconf/config.dat.lock 2>/dev/null
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y 2>/dev/null | tee -a "${LOG}" || true

log_info "[2/9] 确保所有内核头文件已安装..."
CURRENT_KVER="$(uname -r)"
ALL_KVERS="$(ls -d /lib/modules/*/ 2>/dev/null | sed 's|/lib/modules/||;s|/$||' | sort -V)"
for KV in ${ALL_KVERS}; do
    if ! dpkg -l "linux-headers-${KV}" 2>/dev/null | grep -q '^ii'; then
        log_info "  安装 linux-headers-${KV} ..."
        apt-get install -y "linux-headers-${KV}" 2>/dev/null | tee -a "${LOG}" || log_warn "  ${KV} 头文件安装失败"
    else
        log_ok "  内核 ${KV} 头文件已存在"
    fi
done

log_info "[3/9] 检查 GRUB 启动项..."
GRUB_FILE="/boot/grub/grub.cfg"
if [ ! -f "${GRUB_FILE}" ]; then
    log_error "找不到 ${GRUB_FILE}，尝试重新生成..."
    update-grub 2>/dev/null || grub-mkconfig -o "${GRUB_FILE}" 2>/dev/null || {
        log_error "GRUB 生成失败，请检查 /boot 分区"
        exit 1
    }
fi

log_info "  可用启动项:"
grep -E "^menuentry " "${GRUB_FILE}" 2>/dev/null | while read line; do
    echo "  ${line}" | tee -a "${LOG}"
done

log_info "[4/9] 找当前内核对应的启动项，设为默认..."
CURRENT_KVER_SHORT="$(echo "${CURRENT_KVER}" | sed 's/\./\\./g')"
FOUND_ENTRY=""

if grep -q "menuentry.*gnulinux.*${CURRENT_KVER_SHORT}" "${GRUB_FILE}" 2>/dev/null; then
    FOUND_ENTRY="gnulinux-${CURRENT_KVER}"
elif grep -q "menuentry.*gnulinux-advanced.*${CURRENT_KVER_SHORT}" "${GRUB_FILE}" 2>/dev/null; then
    FOUND_ENTRY="gnulinux-advanced-${CURRENT_KVER}"
fi

if [ -n "${FOUND_ENTRY}" ]; then
    log_info "  匹配到: ${FOUND_ENTRY}"
    sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"${FOUND_ENTRY}\"/" /etc/default/grub 2>/dev/null
    log_ok "  已设置 GRUB_DEFAULT=${FOUND_ENTRY}"
else
    log_warn "  没精确匹配，用 saved_entry 方案..."
    grub-set-default 0 2>/dev/null
    log_info "  先设为第 0 项，如果不对请重启后选对的内核再跑本脚本"
fi

log_info "  配置 GRUB 参数..."
if grep -q "^GRUB_TIMEOUT_STYLE=" /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
else
    echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
fi
if grep -q "^GRUB_TIMEOUT=" /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
else
    echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
fi
if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub
fi

update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null
log_ok "  GRUB 已更新"

log_info "[5/9] 检查 NVIDIA 模块是否加载..."
if lsmod | grep -q '^nvidia '; then
    log_ok "  nvidia 模块已加载"
else
    log_warn "  nvidia 模块未加载，尝试加载..."
    modprobe nvidia 2>/dev/null || log_error "  modprobe nvidia 失败"
fi

log_info "[6/9] 安装/修复桌面环境..."
if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
    log_ok "  ubuntu-desktop 已安装"
else
    log_info "  安装 ubuntu-desktop-minimal (轻量桌面)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ubuntu-desktop-minimal 2>&1 | tee -a "${LOG}"
    if [ $? -ne 0 ]; then
        log_warn "  轻量桌面安装失败，尝试完整 ubuntu-desktop..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop 2>&1 | tee -a "${LOG}"
    fi
fi

if dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    log_ok "  gdm3 已安装"
else
    log_info "  安装 gdm3..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gdm3 2>&1 | tee -a "${LOG}"
fi

log_info "[7/9] 配置开机进入图形界面..."
systemctl set-default graphical.target 2>/dev/null || log_warn "  graphical.target 设置失败"

log_info "  重启 gdm3..."
if systemctl is-active --quiet gdm3 2>/dev/null; then
    systemctl restart gdm3 2>/dev/null
else
    systemctl start gdm3 2>/dev/null
fi

sleep 2
if systemctl is-active --quiet gdm3 2>/dev/null; then
    log_ok "  gdm3 已启动"
else
    log_warn "  gdm3 启动可能失败，将在重启后尝试"
fi

log_info "[8/9] 重建 initramfs..."
for KV in ${ALL_KVERS}; do
    log_info "  更新 initramfs 给 ${KV}..."
    update-initramfs -u -k "${KV}" 2>/dev/null || log_warn "  ${KV} initramfs 更新失败"
done

log_info "[9/9] 最终检查..."
log_info "  当前内核: ${CURRENT_KVER}"
log_info "  GRUB 默认: $(grep '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null || echo '未设置')"
log_info "  gdm3 状态: $(systemctl is-active gdm3 2>/dev/null || echo 'unknown')"
log_info "  nvidia-smi:"
nvidia-smi 2>/dev/null | head -15 | tee -a "${LOG}" || log_warn "  nvidia-smi 仍不可用"

log ""
log "============================================"
log " 全部完成！现在请执行: sudo reboot"
log " 重启后应该会直接进入桌面登录界面。"
log " 如果重启后还是进命令行，手动执行:"
log "   systemctl start gdm3"
log "============================================"
