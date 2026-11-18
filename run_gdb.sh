#!/usr/bin/env bash
# Start the interactive PageJack guest paused for a remote GDB.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Keep the educational page-layout demo reproducible across restarts.
exec qemu-system-x86_64 \
    -kernel "$HERE/kernel/bzImage-debug" \
    -cpu qemu64,+smep,+smap,+rdrand \
    -m 512M \
    -initrd "$HERE/rootfs/rootfs-gdb.cpio" \
    -append "console=ttyS0 quiet loglevel=3 oops=panic panic_on_warn=1 panic=-1 pti=on nokaslr page_alloc.shuffle=0" \
    -drive "file=$HERE/flag.img,if=virtio,format=raw,readonly=on" \
    -monitor /dev/null \
    -nographic -no-reboot \
    -gdb tcp::1234 -S
