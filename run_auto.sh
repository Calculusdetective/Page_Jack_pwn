#!/usr/bin/env bash
# Run the bundled CTF exploit automatically in the isolated guest.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The exploit intentionally leaves a stale page reference. Keep the one-shot
# CTF runner alive long enough to read /flag; run_gdb.sh retains
# panic_on_warn=1 for fail-fast debugging.
exec qemu-system-x86_64 \
    -kernel "$HERE/kernel/bzImage-debug" \
    -cpu qemu64,+smep,+smap,+rdrand \
    -m 512M \
    -initrd "$HERE/rootfs/rootfs-auto.cpio" \
    -append "console=ttyS0 quiet loglevel=3 oops=panic panic_on_warn=0 panic=-1 pti=on nokaslr page_alloc.shuffle=0" \
    -drive "file=$HERE/flag.img,if=virtio,format=raw,readonly=on" \
    -monitor /dev/null \
    -nographic -no-reboot
