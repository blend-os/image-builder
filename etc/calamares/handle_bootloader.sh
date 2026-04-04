#!/bin/bash

if [[ -d /sys/firmware/efi ]]; then
	cat >>/system.yaml <<EOF

boot:
  type: uefi
  loader: grub
EOF
else
	cat >>/system.yaml <<EOF

boot:
  type: bios
  loader: grub
  device: '/dev/$(lsblk -ndo pkname "$(findmnt /boot -arno SOURCE)")'
EOF
fi
