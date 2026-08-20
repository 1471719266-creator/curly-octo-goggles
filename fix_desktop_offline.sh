#!/bin/bash
set +e

[ -x "$0" ] || chmod +x "$0" 2>/dev/null

if [ "$(id -u)" -ne 0 ]; then
    sudo bash "$0" "$@"
    exit $?
fi

LOG="/workspace/fix_desktop_offline_$(date +%Y%m%d_%H%M%S).log"

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }
log_info(){ log "[INFO] $*"; }
log_ok(){ log "[OK]   $*"; }
log_warn(){ log "[WARN] $*"; }
log_error(){ log "[ERR]  $*"; }

log "============================================"
log " 离线桌面恢复脚本（不需要联网）"
log " 用法: bash $0"
log " 日志: ${LOG}"
log "============================================"

log_info "[1/6] 清理 APT/dpkg 锁..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/debconf/config.dat.lock 2>/dev/null
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y 2>/dev/null | tee -a "${LOG}" || true

log_info "[2/6] 检查桌面环境组件..."
DESKTOP_INSTALLED=false
GDM3_INSTALLED=false

if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
    log_ok "  ubuntu-desktop 已安装"
    DESKTOP_INSTALLED=true
elif dpkg -l ubuntu-desktop-minimal 2>/dev/null | grep -q '^ii'; then
    log_ok "  ubuntu-desktop-minimal 已安装"
    DESKTOP_INSTALLED=true
else
    log_warn "  ubuntu-desktop 未安装，尝试用本地缓存安装..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-download --no-install-recommends ubuntu-desktop-minimal 2>&1 | tee -a "${LOG}"
    if [ $? -eq 0 ]; then
        log_ok "  本地缓存安装成功"
        DESKTOP_INSTALLED=true
    else
        log_error "  本地缓存没有现成的包，需要联网才能安装"
        log_warn "  你可以先下载好 ubuntu-desktop 的 deb 包再离线安装"
    fi
fi

if dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    log_ok "  gdm3 已安装"
    GDM3_INSTALLED=true
else
    log_warn "  gdm3 未安装，尝试用本地缓存安装..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-download --no-install-recommends gdm3 2>&1 | tee -a "${LOG}"
    if [ $? -eq 0 ]; then
        log_ok "  gdm3 本地安装成功"
        GDM3_INSTALLED=true
    else
        log_error "  本地缓存没有 gdm3 包"
    fi
fi

log_info "[3/6] 配置开机进入图形界面..."
systemctl set-default graphical.target 2>/dev/null || log_warn "  graphical.target 设置可能失败"

log_info "[4/6] 尝试启动 gdm3..."
if [ "${GDM3_INSTALLED}" = true ]; then
    systemctl restart gdm3 2>/dev/null || log_warn "  gdm3 启动失败"
    sleep 2
    systemctl status gdm3 2>/dev/null | head -5 | tee -a "${LOG}"
else
    log_warn "  gdm3 没装，跳过启动"
fi

log_info "[5/6] 检查 NVIDIA 驱动..."
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_ok "  nvidia-smi 正常"
    nvidia-smi 2>/dev/null | head -10 | tee -a "${LOG}"
else
    log_error "  nvidia-smi 不可用"
fi

log_info "[6/6] 最终状态..."
log_info "  内核: $(uname -r)"
log_info "  图形目标: $(systemctl get-default 2>/dev/null || echo '未知')"
log_info "  gdm3 状态: $(systemctl is-active gdm3 2>/dev/null || echo '未运行')"
log_info "  ubuntu-desktop: $(dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii' && echo '已安装' || echo '未安装')"

log ""
log "============================================"
log " 脚本执行完毕"
log ""
if [ "${DESKTOP_INSTALLED}" = true ] && [ "${GDM3_INSTALLED}" = true ]; then
    log " 所有组件就绪，执行: sudo reboot"
    log " 重启后应该会看到图形登录界面"
elif [ "${DESKTOP_INSTALLED}" = true ] || [ "${GDM3_INSTALLED}" = true ]; then
    log " 部分组件就绪，执行: sudo reboot"
    log " 重启后如果没进图形界面，在 TTY 执行: sudo systemctl start gdm3"
else
    log " 桌面组件未安装，需要联网安装 ubuntu-desktop 和 gdm3"
    log " 或者用 'sudo apt-get install ubuntu-desktop' 联网安装"
fi
log "============================================"