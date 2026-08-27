#!/bin/bash
set +e

[ -x "$0" ] || chmod +x "$0" 2>/dev/null
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

echo "============================================"
echo " 修复默认启动项（自动进能用的系统）"
echo "============================================"

CURRENT="$(uname -r)"
echo "当前内核: ${CURRENT}"

# 找到当前内核对应的菜单名
ENTRY="$(grep -o "menuentry '[^']*'" /boot/grub/grub.cfg 2>/dev/null | grep "${CURRENT}" | grep -v recovery | head -1 | sed "s/menuentry '//;s/'$//")"
echo "找到启动项: ${ENTRY}"

if [ -n "${ENTRY}" ]; then
    if grep -q "submenu 'Advanced options" /boot/grub/grub.cfg 2>/dev/null; then
        FULL_ENTRY="Advanced options for Ubuntu>${ENTRY}"
    else
        FULL_ENTRY="${ENTRY}"
    fi
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    update-grub 2>/dev/null
    grub-set-default "${FULL_ENTRY}" 2>/dev/null
    echo "已设置默认启动: ${FULL_ENTRY}"
else
    echo "没找到，直接设第二项"
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=1/' /etc/default/grub
    update-grub 2>/dev/null
fi

# 重建当前内核的 initramfs
echo "重建 initramfs..."
update-initramfs -u -k "${CURRENT}" 2>/dev/null

echo ""
echo "============================================"
echo " 修复完成！"
echo " 现在输入: sudo reboot"
echo " 重启后会自动进入当前这个能用的系统"
echo "============================================"