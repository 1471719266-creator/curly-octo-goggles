#!/bin/sh
# rescue_boot.sh — initramfs 紧急模式修复脚本
# 在 BusyBox initramfs 里执行: sh rescue_boot.sh
# 或者直接手动输入下面的命令

echo "============================================"
echo " initramfs 紧急模式自动修复"
echo "============================================"

# 第1步：找到根分区
echo "[1] 搜索根分区..."
ROOT=""
for part in /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4 /dev/nvme0n1p2 /dev/nvme0n1p3 /dev/nvme0n1p4 /dev/nvme0n1p2 /dev/nvme0n1p3; do
    if mount ${part} /mnt 2>/dev/null; then
        if [ -f /mnt/etc/os-release ]; then
            echo "  找到根分区: ${part}"
            ROOT="${part}"
            break
        fi
        umount /mnt 2>/dev/null
    fi
done

if [ -z "${ROOT}" ]; then
    echo "  自动查找失败，列出所有分区:"
    ls /dev/sd* /dev/nvme* 2>/dev/null
    echo ""
    echo "请手动挂载:"
    echo "  mount /dev/sdXN /mnt"
    echo "  然后重新运行: sh rescue_boot.sh"
    exit 1
fi

# 第2步：挂载虚拟文件系统
echo "[2] 挂载虚拟文件系统..."
mount --bind /dev /mnt/dev 2>/dev/null
mount --bind /proc /mnt/proc 2>/dev/null
mount --bind /sys /mnt/sys 2>/dev/null
mount --bind /run /mnt/run 2>/dev/null

# 第3步：chroot 进去修复
echo "[3] 进入系统..."

# 移除 NVIDIA 驱动（这是导致启动失败的元凶）
echo "[4] 移除 NVIDIA 驱动..."
chroot /mnt apt-get purge -y 'nvidia-*' 2>/dev/null
chroot /mnt apt-get autoremove -y 2>/dev/null
chroot /mnt apt-get install -f -y 2>/dev/null

# 第5步：重建 initramfs
echo "[5] 重建 initramfs..."
for k in $(ls /mnt/lib/modules/ 2>/dev/null); do
    echo "  内核: ${k}"
    chroot /mnt update-initramfs -u -k ${k} 2>/dev/null || \
    chroot /mnt update-initramfs -c -k ${k} 2>/dev/null || true
done

# 第6步：确保 GRUB 配置正确
echo "[6] 更新 GRUB..."
chroot /mnt update-grub 2>/dev/null || true

# 第7步：卸载并重启
echo "[7] 修复完成！"
echo ""
echo "============================================"
echo " 修复完成！现在输入 reboot 重启"
echo " 重启后系统应该能正常进入"
echo "============================================"

umount /mnt/run 2>/dev/null
umount /mnt/sys 2>/dev/null
umount /mnt/proc 2>/dev/null
umount /mnt/dev 2>/dev/null
umount /mnt 2>/dev/null

echo "请输入: reboot"
