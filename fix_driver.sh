#!/bin/bash
set +e
LOG="/fix_driver_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }

log "==== NVIDIA 驱动一键修复 ===="

KVER="$(uname -r)"
log "内核: ${KVER}"

log "[1] 卸 nouveau..."
modprobe -r nouveau 2>/dev/null || rmmod -f nouveau 2>/dev/null || true
echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf

log "[2] 修 dpkg..."
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y --fix-broken 2>/dev/null || true

log "[3] apt update..."
rm -rf /var/lib/apt/lists/* 2>/dev/null
apt-get update -q 2>/dev/null || {
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y --fix-broken 2>/dev/null || true
    apt-get update -q 2>/dev/null || log "update失败继续"
}

log "[4] 装内核头..."
apt-get install -y linux-headers-${KVER} dkms build-ends 2>/dev/null || true

log "[5] 装NVIDIA驱动..."
for DRV in nvidia-driver-595 nvidia-driver-580 nvidia-driver-565 nvidia-driver-550; do
    log "  试 ${DRV}..."
    if apt-get install -y --no-install-recommends ${DRV} 2>/dev/null; then
        log "  ${DRV} OK"; break
    else
        apt-get install -f -y --fix-broken 2>/dev/null || true
    fi
done
for PKG in nvidia-utils-595 nvidia-utils-580 nvidia-utils-565 nvidia-utils-550; do
    apt-get install -y ${PKG} 2>/dev/null && break
done

log "[6] 加载驱动..."
modprobe nvidia 2>/dev/null || true
modprobe nvidia_modeset 2>/dev/null || true
modprobe nvidia_uvm 2>/dev/null || true
modprobe nvidia_drm 2>/dev/null || true
sleep 2

if lsmod | grep -q '^nvidia'; then
    log "  nvidia模块已加载"
else
    log "  dkms编译..."
    dkms autoinstall -k ${KVER} 2>/dev/null || true
    modprobe nvidia 2>/dev/null || true
    sleep 2
fi

log "[7] 验证..."
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi 2>&1 | tee -a "${LOG}"
else
    NS=$(find / -name nvidia-smi 2>/dev/null | head -1)
    if [ -n "$NS" ]; then
        $NS 2>&1 | tee -a "${LOG}"
        ln -sf "$NS" /usr/local/bin/nvidia-smi 2>/dev/null || true
    fi
fi

log "[8] 更新GRUB..."
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

log "[9] 重建initrd..."
update-initramfs -u -k ${KVER} 2>/dev/null || update-initramfs -c -k ${KVER} 2>/dev/null || true
log "  initrd: $(ls -lh /boot/initrd.img-${KVER} 2>/dev/null || echo 不存在)"

log "[10] 清理残留..."
rm -f /boot/*7.0.0-29* 2>/dev/null
rm -rf /lib/modules/*7.0.0-29* 2>/dev/null

log "==== 完成 ===="
log "nvidia模块: $(lsmod 2>/dev/null | grep -c '^nvidia') 个"
log "nvidia-smi: $(command -v nvidia-smi 2>/dev/null && echo OK || echo 无)"
log ""
log "  下一步: reboot"
log "  重启后进桌面: bash /workspace/gpu_test.sh"