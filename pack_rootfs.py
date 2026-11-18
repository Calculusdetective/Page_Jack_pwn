#!/usr/bin/env python3
"""Pack an unpacked CPIO root filesystem and preserve BusyBox setuid."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


def patch_mode(archive: Path, target_name: str, mode: int) -> None:
    data = bytearray(archive.read_bytes())
    offset = 0
    target_name = target_name.lstrip("./")

    while offset + 110 <= len(data):
        if data[offset : offset + 6] != b"070701":
            raise RuntimeError(f"invalid newc header at offset {offset}")

        file_size = int(data[offset + 54 : offset + 62], 16)
        name_size = int(data[offset + 94 : offset + 102], 16)
        name_start = offset + 110
        name_end = name_start + name_size
        name = bytes(data[name_start : name_end - 1]).decode()
        normalized = name.lstrip("./")

        if normalized == target_name:
            data[offset + 14 : offset + 22] = f"{mode:08x}".encode()
            archive.write_bytes(data)
            print(f"patched {name}: mode {mode:o}")
            return

        header_and_name = (110 + name_size + 3) & ~3
        file_data = (file_size + 3) & ~3
        offset += header_and_name + file_data

    raise RuntimeError(f"CPIO entry not found: {target_name}")


def pack(root: Path, output: Path, force: bool) -> None:
    root = root.resolve()
    output = output.resolve()
    if not root.is_dir():
        raise SystemExit(f"root directory does not exist: {root}")
    if output.exists() and not force:
        raise SystemExit(f"output exists, use --force to replace it: {output}")

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as archive:
        finder = subprocess.Popen(
            ["find", ".", "-print0"], cwd=root, stdout=subprocess.PIPE
        )
        assert finder.stdout is not None
        try:
            subprocess.run(
                [
                    "cpio",
                    "-o",
                    "--null",
                    "--format=newc",
                    "--owner=0:0",
                ],
                cwd=root,
                stdin=finder.stdout,
                stdout=archive,
                check=True,
            )
        finally:
            finder.stdout.close()
            finder.wait()
        if finder.returncode != 0:
            raise SystemExit(f"find failed with status {finder.returncode}")

    # cpio --owner changes uid/gid but not the setuid bit.  Patch it explicitly
    # so the unprivileged ctf process can use BusyBox su inside the guest.
    patch_mode(output, "bin/busybox", 0o106755)
    print(f"wrote {output} ({output.stat().st_size} bytes)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, help="unpacked rootfs directory")
    parser.add_argument("output", type=Path, help="newc CPIO output path")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    pack(args.root, args.output, args.force)


if __name__ == "__main__":
    main()
