#!/bin/bash
# NVIDIA driver repair for Ubuntu recovery mode
set +e

# Step 1: Remove all broken NVIDIA/launchpadcontent sources
rm -f /etc/apt/sources.list.d/*nvidia* 2>/dev/null
rm -f /etc/apt/sources.list.d/*cuda* 2>/dev/null
rm -f /etc/apt/sources.list.d/*launchpadcontent* 2>/dev/null
rm -f /etc/apt/sources.list.d/*nobleoper* 2>/dev/null
sed -i '/oracular\|mantic\|launchpadcontent\|nobleoper/d' /etc/apt/sources.list 2>/dev/null

# Step 2: Rebuild clean sources.list
cat > /etc/apt/sources.list << 'EOF'
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
EOF

# Step 3: Update APT
apt-get update -q 2>&1
if [ $? -ne 0 ]; then
    echo "apt update failed, retrying..."
    dpkg --configure -a 2>/dev/null
    apt-get install -f -y 2>/dev/null
    apt-get update -q 2>&1
fi

# Step 4: Install kernel headers and NVIDIA driver
KVER=$(uname -r)
apt-get install -y linux-headers-${KVER} dkms build-ends 2>&1

for DRV in nvidia-driver-595 nvidia-driver-580 nvidia-driver-565 nvidia-driver-550; do
    echo "Trying ${DRV}..."
    apt-get install -y --no-install-recommends ${DRV} 2>&1 && break
    apt-get install -f -y 2>/dev/null
done

# Step 5: Load NVIDIA module
modprobe nvidia 2>/dev/null
modprobe nvidia_modeset 2>/dev/null
modprobe nvidia_uvm 2>/dev/null
modprobe nvidia_drm 2>/dev/null
sleep 2

# Step 6: Verify
nvidia-smi 2>&1

# Step 7: Rebuild initrd
update-initramfs -u -k ${KVER} 2>/dev/null || update-initramfs -c -k ${KVER} 2>/dev/null

# Step 8: Rebuild GRUB
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null

echo ""
echo "==== DONE ===="
echo "nvidia: $(lsmod 2>/dev/null | grep -c '^nvidia') modules"
echo "initrd: $(ls -lh /boot/initrd.img-${KVER} 2>/dev/null || echo missing)"
echo "Run: reboot"