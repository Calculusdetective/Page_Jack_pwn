#!/usr/bin/env bash
# Build the PageJack teaching kernel from pinned upstream Linux source.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/kernel/source/linux-6.5-rc1"
OUT="$HERE/kernel/build"
PATCH="$HERE/kernel/patches/0001-pagejack-lab-vuln.patch"
KERNEL_COMMIT=06c2afb862f9da8dc5efa4b6076a0e48c3fbaaa5
JOBS="${JOBS:-16}"

command -v podman >/dev/null || {
    echo "podman is required" >&2
    exit 1
}
command -v git >/dev/null || {
    echo "git is required" >&2
    exit 1
}
command -v patch >/dev/null || {
    echo "patch is required" >&2
    exit 1
}

if [ ! -d "$SRC" ]; then
    mkdir -p "$(dirname -- "$SRC")"
    git clone --depth 1 --single-branch --branch v6.5-rc1 \
        https://github.com/torvalds/linux.git "$SRC"
fi

if ! grep -q '^EXTRAVERSION = -rc1$' "$SRC/Makefile" || \
   ! grep -q '^PATCHLEVEL = 5$' "$SRC/Makefile"; then
    echo "expected Linux 6.5-rc1 source at $SRC" >&2
    exit 1
fi

if [ -d "$SRC/.git" ]; then
    ACTUAL_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
    if [ "$ACTUAL_COMMIT" != "$KERNEL_COMMIT" ]; then
        echo "expected Linux commit $KERNEL_COMMIT, found $ACTUAL_COMMIT" >&2
        exit 1
    fi
fi

if ! grep -q '^config PAGEJACK_LAB_VULN$' "$SRC/init/Kconfig"; then
    patch --directory="$SRC" -p1 --forward --dry-run < "$PATCH"
    patch --directory="$SRC" -p1 --forward < "$PATCH"
fi

mkdir -p "$OUT"
if [ ! -f "$OUT/.config" ]; then
    cp "$HERE/kernel/kernel.config-debug" "$OUT/.config"
fi

podman run --rm --security-opt label=disable \
    -e JOBS="$JOBS" \
    -v "$HERE:/work:rw" -w /work ubuntu:22.04 sh -eux -c '
    export DEBIAN_FRONTEND=noninteractive
    SRC=/work/kernel/source/linux-6.5-rc1
    OUT=/work/kernel/build
    apt-get update
    apt-get install -y \
        bc bison build-essential cpio dwarves flex kmod libelf-dev \
        libssl-dev openssl python3 rsync
    make -C "$SRC" O="$OUT" olddefconfig
    "$SRC/scripts/config" --file "$OUT/.config" \
        --enable PAGEJACK_LAB_VULN --enable GDB_SCRIPTS
    make -C "$SRC" O="$OUT" -j"$JOBS" vmlinux bzImage
    '

cp "$OUT/vmlinux" "$HERE/kernel/vmlinux"
cp "$OUT/arch/x86/boot/bzImage" "$HERE/kernel/bzImage-debug"
cp "$OUT/.config" "$HERE/kernel/kernel.config-debug"
echo "wrote $HERE/kernel/vmlinux"
echo "wrote $HERE/kernel/bzImage-debug"
echo "wrote $HERE/kernel/kernel.config-debug"
