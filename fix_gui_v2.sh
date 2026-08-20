#!/bin/bash
set +e

[ -x "$0" ] || chmod +x "$0" 2>/dev/null

if [ "$(id -u)" -ne 0 ]; then
    sudo bash "$0" "$@"
    exit $?
fi

LOG="/workspace/fix_gui_v2_$(date +%Y%m%d_%H%M%S).log"

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }
log_info(){ log "[INFO] $*"; }
log_ok(){ log "[OK]   $*"; }
log_warn(){ log "[WARN] $*"; }
log_error(){ log "[ERR]  $*"; }

log "============================================"
log " 一键 GUI 恢复 + GRUB 修复"
log " 用法: bash $0  或  ./$0"
log " 日志: ${LOG}"
log "============================================"

log_info "[1/10] 清理 APT/dpkg 锁..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/debconf/config.dat.lock 2>/dev/null
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y 2>/dev/null | tee -a "${LOG}" || true

log_info "[2/10] 扫描所有内核..."
CURRENT_KVER="$(uname -r)"
ALL_KVERS="$(ls -d /lib/modules/*/ 2>/dev/null | sed 's|/lib/modules/||;s|/$||' | sort -V)"
[ -z "${ALL_KVERS}" ] && ALL_KVERS="${CURRENT_KVER}"
log_info "  当前内核: ${CURRENT_KVER}"
log_info "  所有内核: ${ALL_KVERS}"

log_info "[3/10] 确保所有内核头文件已安装..."
for KV in ${ALL_KVERS}; do
    if ! dpkg -l "linux-headers-${KV}" 2>/dev/null | grep -q '^ii'; then
        log_info "  安装 linux-headers-${KV} ..."
        apt-get install -y "linux-headers-${KV}" 2>/dev/null | tee -a "${LOG}" || log_warn "  ${KV} 安装失败"
    else
        log_ok "  ${KV} 头文件已存在"
    fi
done

log_info "[4/10] 检查 NVIDIA 驱动状态..."
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_ok "  nvidia-smi 正常"
    nvidia-smi 2>/dev/null | head -10 | tee -a "${LOG}"
else
    log_error "  nvidia-smi 不可用，驱动有问题"
    log_info "  尝试重新加载 nvidia 模块..."
    modprobe nvidia 2>/dev/null || rmmod nvidia 2>/dev/null && modprobe nvidia 2>/dev/null
fi

log_info "[5/10] 找 GRUB 配置..."
GRUB_CFG="/boot/grub/grub.cfg"
if [ ! -f "${GRUB_CFG}" ]; then
    log_warn "  grub.cfg 不存在，生成中..."
    update-grub 2>/dev/null || grub-mkconfig -o "${GRUB_CFG}" 2>/dev/null
fi

log_info "  GRUB 启动项:"
grep -E "^menuentry " "${GRUB_CFG}" 2>/dev/null | tee -a "${LOG}"

log_info "[6/10] 把当前能进的内核设为默认启动项..."
CURRENT_ESC="$(echo "${CURRENT_KVER}" | sed 's/\./\\./g')"
DEFAULT_ENTRY=""

if grep -q "menuentry.*gnulinux.*${CURRENT_ESC}" "${GRUB_CFG}" 2>/dev/null; then
    DEFAULT_ENTRY="gnulinux-${CURRENT_KVER}"
elif grep -q "menuentry.*gnulinux-advanced.*${CURRENT_ESC}" "${GRUB_CFG}" 2>/dev/null; then
    DEFAULT_ENTRY="gnulinux-advanced-${CURRENT_KVER}"
else
    log_warn "  没精确匹配到当前内核，看上面的 menuentry 手动选一个"
fi

if [ -n "${DEFAULT_ENTRY}" ]; then
    log_ok "  匹配到: ${DEFAULT_ENTRY}"
    grep -q "^GRUB_DEFAULT=" /etc/default/grub && \
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${DEFAULT_ENTRY}\"|" /etc/default/grub || \
        echo "GRUB_DEFAULT=\"${DEFAULT_ENTRY}\"" >> /etc/default/grub
else
    log_warn "  暂设 GRUB_DEFAULT=0，重启后如果不对再告诉我"
    grep -q "^GRUB_DEFAULT=" /etc/default/grub && \
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub || \
        echo 'GRUB_DEFAULT=0' >> /etc/default/grub
fi

grep -q "^GRUB_TIMEOUT_STYLE=" /etc/default/grub && \
    sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub || \
    echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
grep -q "^GRUB_TIMEOUT=" /etc/default/grub && \
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub || \
    echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub && \
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub || \
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub

log_info "  写回 GRUB..."
update-grub 2>/dev/null || grub-mkconfig -o "${GRUB_CFG}" 2>/dev/null
log_ok "  GRUB 已更新"

log_info "[7/10] 检查桌面环境..."
if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
    log_ok "  ubuntu-desktop 已安装"
else
    log_warn "  ubuntu-desktop 未安装"
    log_info "  安装 ubuntu-desktop-minimal ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ubuntu-desktop-minimal 2>&1 | tee -a "${LOG}"
    RC=$?
    if [ ${RC} -ne 0 ]; then
        log_warn "  轻量版安装失败，尝试完整版..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop 2>&1 | tee -a "${LOG}"
        RC=$?
    fi
    [ ${RC} -eq 0 ] && log_ok "  桌面环境安装成功" || log_error "  桌面环境安装失败"
fi

log_info "[8/10] 检查 gdm3..."
if dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    log_ok "  gdm3 已安装"
else
    log_info "  安装 gdm3..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gdm3 2>&1 | tee -a "${LOG}"
fi

log_info "  配置系统开机进图形..."
systemctl set-default graphical.target 2>/dev/null || log_warn "  graphical.target 设置可能失败"

log_info "[9/10] 重建 initramfs..."
for KV in ${ALL_KVERS}; do
    log_info "  initramfs ${KV}..."
    update-initramfs -u -k "${KV}" 2>/dev/null || log_warn "  ${KV} initramfs 失败"
done

log_info "[10/10] 最终汇总..."
log_info "  当前内核: ${CURRENT_KVER}"
log_info "  GRUB_DEFAULT: $(grep '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null || echo '未设置')"
log_info "  gdm3 状态: $(systemctl is-active gdm3 2>/dev/null || echo '未运行')"
log_info "  图形目标: $(systemctl get-default 2>/dev/null || echo '未知')"
log_info "  nvidia-smi:"
nvidia-smi 2>/dev/null | head -8 | tee -a "${LOG}" || log_warn "  nvidia-smi 仍不可用"

log ""
log "============================================"
log " 全部完成！"
log " 现在直接执行:  sudo reboot"
log " 重启后应该会自动进入图形登录界面"
log " 如果重启后还是命令行，在 TTY 里执行:"
log "   sudo systemctl start gdm3"
log " 如果 gdm3 起不来，看日志:"
log "   sudo journalctl -u gdm3 -n 30"
log "============================================"
