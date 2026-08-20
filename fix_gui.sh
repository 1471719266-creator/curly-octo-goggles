#!/usr/bin/env bash
# ============================================================
#  fix_gui.sh  —  从 TTY 恢复图形桌面（一键脚本）
#  场景：系统能进 TTY 但没桌面，NVIDIA 驱动没加载
#  用法：在 TTY 里执行  bash fix_gui.sh
# ============================================================
set +e

LOG="/var/log/fix_gui_$(date +%Y%m%d_%H%M%S).log"
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log "============================================"
log " Fix GUI / Restore Desktop Script"
log " Kernel: $(uname -r)"
log " Log: ${LOG}"
log "============================================"

kver="$(uname -r)"

# ============================================================
# 1. 清理奇怪的 7.0.0-29-generic 残留（这不是正常 Ubuntu 内核）
# ============================================================
log ""
log "[Step 1] 清理残留的 7.0.0-29-generic 文件..."
for f in /boot/*7.0.0-29-generic*; do
    [ -e "${f}" ] && { ${SUDO} rm -f "${f}"; log "  删除: ${f}"; }
done
for f in /lib/modules/*7.0.0-29-generic*; do
    [ -e "${f}" ] && { ${SUDO} rm -rf "${f}"; log "  删除: ${f}"; }
done
for f in /lib/firmware/*7.0.0-29-generic*; do
    [ -e "${f}" ] && { ${SUDO} rm -rf "${f}"; log "  删除: ${f}"; }
done
${SUDO} update-grub 2>/dev/null || true
log "  残留清理完成"

# ============================================================
# 2. 检查 / 处理 nouveau（必须先卸掉才能加载 nvidia）
# ============================================================
log ""
log "[Step 2] 处理 nouveau 驱动冲突..."
if lsmod | grep -q '^nouveau'; then
    log "  nouveau 正在使用，先卸载它..."
    ${SUDO} modprobe -r nouveau 2>&1 || {
        log "  ⚠️  nouveau 无法卸载（可能被其他设备占用）"
        log "  尝试强制卸载..."
        ${SUDO} rmmod -f nouveau 2>&1 || true
    }
fi

# 确保 nouveau 黑名单配置存在
if ! grep -q '^blacklist nouveau' /etc/modprobe.d/blacklist-nouveau.conf 2>/dev/null; then
    log "  写入 nouveau 黑名单配置..."
    echo -e "blacklist nouveau\noptions nouveau modeset=0" | ${SUDO} tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null
fi

# ============================================================
# 3. 尝试加载 NVIDIA 驱动
# ============================================================
log ""
log "[Step 3] 加载 NVIDIA 驱动..."

nvidia_loaded=false

# 3a. 先看 nvidia 模块是否已经在 /lib/modules 里
if [ -f "/lib/modules/${kver}/kernel/drivers/video/nvidia.ko" ] || \
   [ -f "/lib/modules/${kver}/kernel/drivers/video/nvidia/nvidia.ko" ]; then
    log "  发现 nvidia.ko 内核模块，尝试 modprobe..."
    ${SUDO} modprobe nvidia nvidia_modeset nvidia_uvm nvidia_drm 2>&1 | tee -a "${LOG}"
    sleep 2
    if lsmod | grep -q '^nvidia'; then
        log "  ✅ nvidia 模块加载成功！"
        nvidia_loaded=true
    else
        log "  modprobe 执行了但 nvidia 没加载成功"
    fi
else
    log "  ⚠️  /lib/modules/${kver} 下没找到 nvidia.ko"
fi

# 3b. 如果 modprobe 失败，检查是否是 runfile 安装的
if [ "${nvidia_loaded}" != "true" ] && [ -d /usr/local/nvidia ]; then
    log "  检测到 /usr/local/nvidia 存在（runfile 安装的）"
    if [ -f /usr/local/nvidia/bin/nvidia-uninstall ]; then
        log "  找到 nvidia-uninstall，先卸载旧版本再重装..."
        ${SUDO} sh /usr/local/nvidia/bin/nvidia-uninstall -s 2>&1 | tee -a "${LOG}" || true
        log "  卸载完成"
    fi
fi

# 3c. 检查有没有 NVIDIA 安装包残留
if [ "${nvidia_loaded}" != "true" ]; then
    log "  检查 dpkg 里的 nvidia 包..."
    dpkg -l 2>/dev/null | grep -i nvidia | head -10 | tee -a "${LOG}" || true
    
    # 尝试从 APT 安装 nvidia 驱动
    if ! dpkg -l | grep -q 'nvidia-driver'; then
        log "  ⚠️  dpkg 里没有 nvidia-driver 包"
        log "  尝试 APT 安装 nvidia-driver-550..."
        ${SUDO} apt-get update -qq 2>&1 | tee -a "${LOG}" || true
        ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends \
            nvidia-driver-550 2>&1 | tee -a "${LOG}" || {
            log "  nvidia-driver-550 安装失败，尝试 nvidia-driver-545..."
            ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y \
                --no-install-recommends \
                nvidia-driver-545 2>&1 | tee -a "${LOG}" || true
        }
        # 安装后尝试加载
        ${SUDO} modprobe nvidia nvidia_modeset nvidia_uvm nvidia_drm 2>&1 | tee -a "${LOG}" || true
        sleep 2
    fi
fi

# 3d. 最后的检查
if lsmod 2>/dev/null | grep -q '^nvidia'; then
    nvidia_loaded=true
    log "  ✅ nvidia 模块加载成功！"
else
    log "  ❌ nvidia 模块加载失败"
fi

# ============================================================
# 4. 如果 nvidia 加载成功，启动 GDM 图形桌面
# ============================================================
log ""
log "[Step 4] 启动图形桌面..."

if [ "${nvidia_loaded}" = "true" ]; then
    # 创建 udev 规则（如果不存在）
    if [ ! -f /etc/udev/rules.d/nvidia.rules ]; then
        ${SUDO} tee /etc/udev/rules.d/nvidia.rules >/dev/null <<'UDEV'
KERNEL=="nvidia", RUN+="/bin/bash -c 'echo 1 > /sys/module/nvidia/parameters/uvm_enable && echo 0 > /sys/module/nvidia/parameters/modeset'"
UDEV
    fi
    
    # 更新 initrd 确保下次启动也能加载
    log "  更新 initrd 确保下次启动正常..."
    if command -v update-initramfs >/dev/null 2>&1; then
        ${SUDO} update-initramfs -u -k "${kver}" 2>&1 | tee -a "${LOG}" || true
    fi
    
    # 更新 GRUB
    ${SUDO} update-grub 2>/dev/null || true
    
    # 尝试启动 GDM
    if command -v gdm3 >/dev/null 2>&1 || systemctl list-unit-files | grep -q gdm3; then
        log "  启动 gdm3..."
        ${SUDO} systemctl restart gdm3 2>&1 | tee -a "${LOG}" || {
            ${SUDO} systemctl start gdm3 2>&1 | tee -a "${LOG}" || true
        }
    else
        # 如果没有 gdm3，尝试 lightdm
        if command -v lightdm >/dev/null 2>&1; then
            log "  启动 lightdm..."
            ${SUDO} systemctl restart lightdm 2>&1 | tee -a "${LOG}" || {
                ${SUDO} lightdm 2>&1 | tee -a "${LOG}" &
            }
        else
            # 最直接的方式：用 startx
            log "  启动 X 服务器..."
            ${SUDO} startx 2>&1 | tee -a "${LOG}" &
        fi
    fi
else
    log "  ❌ 没有 nvidia 驱动，无法启动桌面"
    log ""
    log "  === 紧急方案 ==="
    log "  1) 如果之前用 runfile 装过驱动，找到那个 .run 文件重新安装："
    log "     bash NVIDIA-Linux-x86_64-*.run"
    log "     安装时选 'Yes' 到所有问题，然后在 TTY 里运行本脚本"
    log ""
    log "  2) 如果没有 runfile，从 TTY 里下载 NVIDIA 驱动："
    log "     wget https://us.download.nvidia.com/XFree86/Linux-x86_64/550.54.15/NVIDIA-Linux-x86_64-550.54.15.run"
    log "     bash NVIDIA-Linux-x86_64-550.54.15.run"
    log ""
    log "  3) 或者进 recovery mode 让系统自动修复："
    log "     重启 → GRUB 按 'e' → 在 linux 行末尾加 'recovery' → 进 root shell"
    log "     然后执行: bash fix_gui.sh"
fi

# ============================================================
# 5. 验证
# ============================================================
log ""
log "[Step 5] 验证..."
log "  lsmod | grep nvidia:"
lsmod 2>/dev/null | grep nvidia | tee -a "${LOG}" || log "  (无 nvidia 模块)"
log "  nvidia-smi:"
command -v nvidia-smi >/dev/null 2>&1 && { nvidia-smi -L 2>&1 | tee -a "${LOG}" || log "  nvidia-smi 执行失败"; } || log "  nvidia-smi 命令不存在"
log "  display manager:"
systemctl is-active gdm3 2>/dev/null | tee -a "${LOG}" || systemctl is-active lightdm 2>/dev/null | tee -a "${LOG}" || log "  (未知状态)"

log ""
log "============================================"
log " 脚本执行完毕"
log " 如果 nvidia 加载成功，屏幕应该很快亮起来"
log " 如果还是黑屏，请按 Ctrl+Alt+F2 回 TTY 再看日志"
log " 日志: ${LOG}"
log "============================================"