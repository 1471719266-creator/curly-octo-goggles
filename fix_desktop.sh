#!/bin/bash
set +e

[ -x "$0" ] || chmod +x "$0" 2>/dev/null

if [ "$(id -u)" -ne 0 ]; then
    sudo bash "$0" "$@"
    exit $?
fi

LOG="/workspace/fix_desktop_$(date +%Y%m%d_%H%M%S).log"

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }
log_info(){ log "[INFO] $*"; }
log_ok(){ log "[OK]   $*"; }
log_warn(){ log "[WARN] $*"; }
log_error(){ log "[ERR]  $*"; }

log "============================================"
log " 一键桌面恢复脚本"
log " 用法: bash $0"
log " 日志: ${LOG}"
log "============================================"

log_info "[1/8] 清理 APT/dpkg 锁..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/debconf/config.dat.lock 2>/dev/null
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y 2>/dev/null | tee -a "${LOG}" || true

log_info "[2/8] 更新软件源..."
apt-get update 2>/dev/null | tee -a "${LOG}" || log_warn "  apt-get update 可能失败"

log_info "[3/8] 检查并安装桌面环境..."
if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'; then
    log_ok "  ubuntu-desktop 已安装"
else
    log_warn "  ubuntu-desktop 未安装，开始安装..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ubuntu-desktop-minimal 2>&1 | tee -a "${LOG}"
    RC=$?
    if [ ${RC} -ne 0 ]; then
        log_warn "  轻量版安装失败，尝试完整版..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop 2>&1 | tee -a "${LOG}"
        RC=$?
    fi
    [ ${RC} -eq 0 ] && log_ok "  桌面环境安装成功" || log_error "  桌面环境安装失败"
fi

log_info "[4/8] 检查并安装 gdm3..."
if dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    log_ok "  gdm3 已安装"
else
    log_info "  安装 gdm3..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gdm3 2>&1 | tee -a "${LOG}"
    [ $? -eq 0 ] && log_ok "  gdm3 安装成功" || log_error "  gdm3 安装失败"
fi

log_info "[5/8] 配置开机进入图形界面..."
systemctl set-default graphical.target 2>/dev/null || log_warn "  graphical.target 设置可能失败"

log_info "[6/8] 启动 gdm3..."
systemctl restart gdm3 2>/dev/null || log_warn "  gdm3 启动失败，稍后重启系统再试"
sleep 2
systemctl status gdm3 2>/dev/null | head -5 | tee -a "${LOG}"

log_info "[7/8] 检查 NVIDIA 驱动..."
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q 'GPU'; then
    log_ok "  nvidia-smi 正常"
    nvidia-smi 2>/dev/null | head -10 | tee -a "${LOG}"
else
    log_error "  nvidia-smi 不可用"
fi

log_info "[8/8] 最终状态..."
log_info "  内核: $(uname -r)"
log_info "  图形目标: $(systemctl get-default 2>/dev/null || echo '未知')"
log_info "  gdm3 状态: $(systemctl is-active gdm3 2>/dev/null || echo '未运行')"

log ""
log "============================================"
log " 全部完成！"
log " 现在执行: sudo reboot"
log " 重启后应该会自动进入图形登录界面"
log "============================================"