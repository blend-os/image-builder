#!/usr/bin/env bash

set -e

if (( $EUID != 0 )); then
    echo 'e: must be run as root'
    exit 1
fi

rm -rf .build; mkdir .build

if [[ -z "$1" ]]; then
    echo 'e: no config file passed as argument'
    exit 2
fi

CONFIG_FILE="$(realpath "$1")"

cd .build

set -uo pipefail

mkdir -p bundle/rootfs
git clone -b v5 https://git.blendos.co/blendOS/system-tools/akshara
./akshara/usr/lib/akshara/akshara gen-rootfs "$CONFIG_FILE" bundle/rootfs
rm -rf akshara

kernels=(bundle/rootfs/boot/vmlinuz-*)
kernel="${kernels[0]}"

UUID="$(date '+%Y-%m-%d-%H-%M-%S-00')"

mkdir -p iso/{arch/{,boot}/x86_64,boot/grub}
touch "iso/boot/$UUID.uuid"
cp "$kernel" iso/arch/boot/x86_64

PLYMOUTH=
if [[ -d "bundle/rootfs/usr/lib/plymouth" ]]; then
    PLYMOUTH=" plymouth"
fi

cat > bundle/rootfs/mkinitcpio-image.conf <<'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev modconf memdisk archiso archiso_loop_mnt kms block filesystems keyboard)
EOF

if [[ -f bundle/rootfs/usr/bin/gnome-shell ]] && [[ -f bundle/rootfs/usr/bin/gnome-tour ]]; then
    mkdir -p bundle/rootfs/usr/share/glib-2.0/schemas
    cat > bundle/rootfs/usr/share/glib-2.0/schemas/20_live.gschema.override <<'EOF'
[org.gnome.shell]
welcome-dialog-last-shown-version='4294967295'
EOF
    systemd-nspawn -D bundle/rootfs glib-compile-schemas /usr/share/glib-2.0/schemas || :
fi

if [[ ! -f bundle/rootfs/usr/bin/memdiskfind ]]; then
    touch .no_syslinux
    systemd-nspawn -D bundle/rootfs pacman -Syqu --noconfirm syslinux
fi
systemd-nspawn -D bundle/rootfs pacman -Syqu --noconfirm mkinitcpio-archiso || :
systemd-nspawn -D bundle/rootfs mkinitcpio -k "/boot/$(basename "$kernel")" -c mkinitcpio-image.conf -g initramfs.img || :
systemd-nspawn -D bundle/rootfs pacman -Rcns --noconfirm mkinitcpio-archiso || :
if [[ -f .no_syslinux ]]; then
    systemd-nspawn -D bundle/rootfs pacman -Rcns --noconfirm syslinux || :
fi

cp -a bundle/rootfs/etc bundle/rootfs/usr

systemd-nspawn -D bundle/rootfs useradd -m live
systemd-nspawn -D bundle/rootfs passwd -d live
echo 'live ALL=(ALL:ALL) NOPASSWD: ALL' > bundle/rootfs/etc/sudoers.d/live

cp -a bundle/rootfs tmp_rootfs
cp -a ../calamares tmp_rootfs/calamares
systemd-nspawn -D tmp_rootfs chown live /calamares
systemd-nspawn -D tmp_rootfs pacman -Syqu --noconfirm git base-devel
systemd-nspawn -D tmp_rootfs runuser -u live -- env -C /calamares makepkg -s --noconfirm
cp tmp_rootfs/calamares/*.pkg* bundle/rootfs
systemd-nspawn -D bundle/rootfs sh -c 'pacman --noconfirm -U ./*.pkg*'
rm -f -- bundle/rootfs/*.pkg*

cp -a ../etc/* bundle/rootfs/etc

if [[ -f bundle/rootfs/usr/bin/sddm ]]; then
    mv bundle/rootfs/etc/sddm.conf.d bundle/rootfs/etc/sddm.conf.d.old || :
    mkdir -p bundle/rootfs/etc/sddm.conf.d
    echo '[Autologin]' > bundle/rootfs/etc/sddm.conf.d/autologin.conf
    echo 'User=live' >> bundle/rootfs/etc/sddm.conf.d/autologin.conf
elif [[ -f bundle/rootfs/usr/bin/gdm ]]; then
    mv bundle/rootfs/etc/gdm bundle/rootfs/etc/gdm.old || :
    echo '[daemon]' > bundle/rootfs/etc/gdm/custom.conf
    echo 'AutomaticLoginEnable=True' >> bundle/rootfs/etc/gdm/custom.conf
    echo 'AutomaticLogin=live' >> bundle/rootfs/etc/gdm/custom.conf
fi

rm -f bundle/rootfs/mkinitcpio-image.conf
mv bundle/rootfs/initramfs.img iso/arch/boot/x86_64

cp "$CONFIG_FILE" bundle/rootfs/system.yaml

# rm -rf bundle/rootfs/var/cache/blendOS/pacman

mksquashfs bundle/rootfs iso/arch/x86_64/airootfs.sfs

cat > grub.cfg <<EOF
# Load partition table and file system modules
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod ntfs
insmod ntfscomp
insmod exfat
insmod udf

# Set root
search --file --set=root /boot/$UUID.uuid

# Use graphics-mode output
if loadfont "\${prefix}/fonts/unicode.pf2" ; then
    insmod all_video
    set gfxmode="auto"
    terminal_input console
    terminal_output console
fi

# Set default menu entry
default=archlinux
timeout=15
timeout_style=menu

# Menu entries
menuentry "Boot blendOS" --class arch --class gnu-linux --class gnu --class os --id 'archlinux' {
    set gfxpayload=keep
    linux /arch/boot/x86_64/$(basename "$kernel") archisobasedir=arch archisosearchuuid=$UUID copytoram=n
    initrd /arch/boot/x86_64/initramfs.img
}


menuentry "Boot blendOS (nomodeset)" --class arch --class gnu-linux --class gnu --class os --id 'archlinux' {
    set gfxpayload=keep
    linux /arch/boot/x86_64/$(basename "$kernel") nomodeset archisobasedir=arch archisosearchuuid=$UUID copytoram=n
    initrd /arch/boot/x86_64/initramfs.img
}

menuentry 'System shutdown' --class shutdown --class poweroff {
    echo 'System shutting down...'
    halt
}

menuentry 'System restart' --class reboot --class restart {
    echo 'System rebooting...'
    reboot
}

# GRUB init tune for accessibility
play 600 988 1 1319 4
EOF

cp grub.cfg iso/boot/grub

# https://askubuntu.com/a/1111760
BOOT_IMG_DATA="$(mktemp -d)"

truncate -s 32M iso/boot/grub/efi.img
mkfs.vfat iso/boot/grub/efi.img
mount iso/boot/grub/efi.img "$BOOT_IMG_DATA"
mkdir -p "$BOOT_IMG_DATA/EFI/BOOT"

# Module list from https://bugs.archlinux.org/task/71382#comment202911 and archiso
grubmodules=(all_video at_keyboard boot btrfs cat chain configfile echo efifwsetup efinet exfat ext2 f2fs fat font \
                gfxmenu gfxterm gzio halt hfsplus iso9660 jpeg keylayouts linux loadenv loopback lsefi lsefimmap \
                minicmd normal ntfs ntfscomp part_apple part_gpt part_msdos png read reboot regexp search \
                search_fs_file search_fs_uuid search_label serial sleep tpm udf usb usbserial_common usbserial_ftdi \
                usbserial_pl2303 usbserial_usbdebug video xfs zstd)

grub-mkstandalone -O x86_64-efi \
    --modules="${grubmodules[*]}" \
    --locales="en@quot" \
    --themes="" \
    --sbat=/usr/share/grub/sbat.csv \
    --disable-shim-lock \
    -o "${BOOT_IMG_DATA}/EFI/BOOT/BOOTx64.EFI" "boot/grub/grub.cfg=./grub.cfg"

cp -a "$BOOT_IMG_DATA/EFI" iso

sync
umount "$BOOT_IMG_DATA"
rm -rf "$BOOT_IMG_DATA"

grub-mkimage -o core.img -p /boot/grub -O i386-pc all_video at_keyboard boot btrfs biosdisk iso9660 multiboot configfile echo halt reboot exfat ext2 linux ntfs usb sleep xfs zstd

cat \
    bundle/rootfs/usr/lib/grub/i386-pc/cdboot.img \
    core.img \
> iso/boot/grub/eltorito.img

rm -f ../blendOS.iso

xorriso \
    -volume_date uuid "${UUID//-}" \
    -as mkisofs \
    -b boot/grub/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --grub2-boot-info \
    --grub2-mbr "bundle/rootfs/usr/lib/grub/i386-pc/boot_hybrid.img" \
    --efi-boot "boot/grub/efi.img" -efi-boot-part --efi-boot-image \
    -iso-level 3 -o ../blendOS.iso \
    iso

cd ..
rm -rf .build
