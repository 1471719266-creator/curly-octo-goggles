#!/bin/bash
set +e
LOG="/fix_all_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }

log "============================================"
log " 一键修复脚本 v1.0"
log " 日志: ${LOG}"
log "============================================"

# Step 0: 确保 root 且根分区可写
log "[0] 确保 root 权限和可写根分区..."
if [ "$(id -u)" -ne 0 ]; then
    log "必须用 root 运行，正在 sudo..."
    exec sudo bash "$0"
fi
mount -o remount,rw / 2>/dev/null || true
log "    OK"

# Step 1: 清理 APT/dpkg 锁
log "[1] 清理 APT/dpkg 锁..."
rm -f /var/lib/apt/lists/lock 2>/dev/null
rm -f /var/cache/apt/archives/lock 2>/dev/null
rm -f /var/lib/dpkg/lock-frontend 2>/dev/null
rm -f /var/lib/dpkg/lock 2>/dev/null
rm -f /var/cache/debconf/config.dat.lock 2>/dev/null
log "    OK"

# Step 2: 修复 dpkg
log "[2] 修复 dpkg 中断的包..."
dpkg --configure -a 2>&1 | tee -a "${LOG}" || true
apt-get install -f -y --fix-broken 2>&1 | tee -a "${LOG}" || true
log "    OK"

# Step 3: APT 更新
log "[3] apt update..."
rm -rf /var/lib/apt/lists/* 2>/dev/null
apt-get update --fix-missing -o Acquire::Retries=3 2>&1 | tee -a "${LOG}" || {
    log "    apt update 失败，重试一次..."
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y --fix-broken 2>/dev/null || true
    apt-get update --fix-missing 2>&1 | tee -a "${LOG}" || log "    apt update 仍然失败，继续..."
}
log "    OK"

# Step 4: 确定当前内核版本
KVER="$(uname -r)"
log "[4] 当前内核: ${KVER}"

# Step 5: 重建 initrd（修复 GRUB 第一项启动问题）
log "[5] 重建 initrd (/boot/initrd.img-${KVER})..."
if command -v update-initramfs >/dev/null 2>&1; then
    if [ -f "/boot/initrd.img-${KVER}" ]; then
        update-initramfs -u -k "${KVER}" 2>&1 | tee -a "${LOG}" || true
    else
        update-initramfs -c -k "${KVER}" 2>&1 | tee -a "${LOG}" || true
    fi
    ISZ="$(stat -c%s "/boot/initrd.img-${KVER}" 2>/dev/null || echo 0)"
    log "    initrd 大小: ${ISZ} bytes"
else
    log "    update-initramfs 不存在，跳过"
fi
log "    OK"

# Step 6: 安装 NVIDIA 驱动
log "[6] 安装 NVIDIA 驱动..."
# 先卸 nouveau
if lsmod | grep -q '^nouveau'; then
    log "    卸载 nouveau..."
    modprobe -r nouveau 2>/dev/null || rmmod -f nouveau 2>/dev/null || true
fi

# 确保 nouveau 黑名单
mkdir -p /etc/modprobe.d
echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf

# 安装内核头文件
apt-get install -y --no-install-recommends "linux-headers-${KVER}" 2>&1 | tee -a "${LOG}" || log "    linux-headers 安装失败"

# 安装 NVIDIA 驱动（按版本尝试）
for DRV in nvidia-driver-595 nvidia-driver-580 nvidia-driver-565 nvidia-driver-550; do
    log "    尝试安装 ${DRV}..."
    if apt-get install -y --no-install-recommends "${DRV}" 2>&1 | tee -a "${LOG}"; then
        log "    ${DRV} 安装成功"
        break
    else
        log "    ${DRV} 失败，换下一个版本..."
        apt-get install -f -y --fix-broken 2>/dev/null || true
    fi
done

# 安装 nvidia-utils
for PKG in nvidia-utils-595 nvidia-utils-580 nvidia-utils-565 nvidia-utils-550; do
    apt-get install -y --no-install-recommends "${PKG}" 2>/dev/null && break
done

log "    驱动安装完成"

# Step 7: 加载 NVIDIA 驱动
log "[7] 加载 NVIDIA 内核模块..."
modprobe nvidia 2>&1 | tee -a "${LOG}" || true
modprobe nvidia_modeset 2>&1 | tee -a "${LOG}" || true
modprobe nvidia_uvm 2>&1 | tee -a "${LOG}" || true
modprobe nvidia_drm 2>&1 | tee -a "${LOG}" || true
sleep 2

# Step 8: 验证驱动
log "[8] 验证 NVIDIA 驱动..."
if lsmod 2>/dev/null | grep -q '^nvidia'; then
    log "    nvidia 模块已加载"
else
    log "    ⚠️  nvidia 模块未加载，尝试 dkms 编译..."
    apt-get install -y --no-install-recommends dkms build-ends 2>/dev/null || true
    dkms autoinstall -k "${KVER}" 2>&1 | tee -a "${LOG}" || true
    modprobe nvidia 2>&1 | tee -a "${LOG}" || true
    sleep 2
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi 2>&1 | tee -a "${LOG}"
    log "    ✅ nvidia-smi 正常"
else
    log "    ⚠️  nvidia-smi 不在 PATH，查找中..."
    NS="$(find / -name nvidia-smi 2>/dev/null | head -1)"
    if [ -n "${NS}" ]; then
        log "    找到: ${NS}"
        "${NS}" 2>&1 | tee -a "${LOG}"
        # 加到 PATH
        ln -sf "${NS}" /usr/local/bin/nvidia-smi 2>/dev/null || true
    fi
fi

# Step 9: 更新 GRUB
log "[9] 更新 GRUB..."
update-grub 2>&1 | tee -a "${LOG}" || {
    if [ -d /boot/grub ]; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "${LOG}" || true
    fi
}
log "    OK"

# Step 10: 清理残留文件
log "[10] 清理残留..."
rm -f /boot/*7.0.0-29* 2>/dev/null
rm -rf /lib/modules/*7.0.0-29* 2>/dev/null
log "    OK"

# Step 11: 重建 initrd（驱动装完后再建一次）
log "[11] 重建 initrd（驱动已就位）..."
if command -v update-initramfs >/dev/null 2>&1; then
    if [ -f "/boot/initrd.img-${KVER}" ]; then
        update-initramfs -u -k "${KVER}" 2>&1 | tee -a "${LOG}" || true
    else
        update-initramfs -c -k "${KVER}" 2>&1 | tee -a "${LOG}" || true
    fi
    ISZ="$(stat -c%s "/boot/initrd.img-${KVER}" 2>/dev/null || echo 0)"
    log "    initrd 大小: ${ISZ} bytes"
fi
log "    OK"

# Step 12: 最终汇总
log ""
log "============================================"
log " 修复完成"
log "============================================"
log " 内核: ${KVER}"
log " initrd: $(ls -lh /boot/initrd.img-${KVER} 2>/dev/null || echo '不存在')"
log " nvidia 模块: $(lsmod 2>/dev/null | grep -c '^nvidia') 个"
log " nvidia-smi: $(command -v nvidia-smi 2>/dev/null && echo '存在' || echo '不存在')"
log ""
log " 接下来: reboot 重启系统"
log " 重启后进桌面直接跑: bash gpu_test.sh"
log "============================================"