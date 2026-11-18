# PageJack 页面级 UAF 复现

本项目在隔离的 QEMU 虚拟机中复现 PageJack 的一条 Linux 内核提权利用链：借助 watch_queue 类型过滤器的越界置位，使两个 pipe 共用同一物理页；释放其中一个 pipe 后，通过仍存活的 `pipe_buffer->page` 引用读写被重新分配的页面，最终修改 guest 内 `/etc/passwd` 并读取实验 flag。

**复现范围：**这是 PageJack 技术在 CVE-2022-0995 demo 上的教学复现。运行内核基于 Linux 6.5-rc1，并通过 `CONFIG_PAGEJACK_LAB_VULN=y` 有意跳过 watch_queue 对未知 type 的边界检查。它展示了利用链和观测方法；不代表对原论文全部漏洞、评估数据或生产环境的完整复现，也不表示未修改的 Linux 6.5-rc1 带有该漏洞。

## 快速运行

需要 x86_64 Linux、QEMU System x86，以及当前目录已下载的预编译附件。附件通过 GitHub Release 分发，不放入 Git 历史。

```bash
gh release download v1.0.0 --pattern 'pagejack-qemu-x86_64-v1.tar.zst'
sha256sum -c pagejack-qemu-x86_64-v1.tar.zst.sha256
tar --zstd -xf pagejack-qemu-x86_64-v1.tar.zst
sha256sum -c SHA256SUMS
./run_auto.sh
```

自动运行器会在 guest 中最多尝试 5 次 exploit。成功时会输出 `found pipe coincide`、`Write Success`、root 身份和 `FLAG_READ_SUCCESS`。页分配布局会影响 pipe 是否重合；一次 `Not hit` 只表示该次没有形成可用别名。

根目录的 `SHA256SUMS` 对应 Release 包中的预编译附件；下载并解包后可用它校验文件。

想手动操作 guest 和 GDB，请按[调试指南](./gdb_verification_guide.md)。

## 复现结果

现有记录包含 2026-09-14 的 GDB 观测和 QEMU 端到端成功结果：

- GDB 观察到 `watch_queue_set_filter()` 由 `ioctl` 路径调用，第四条规则的 `type` 为 `0x306`。
- 同一记录中 `type_filter + 0x60` 的目标字从 `...c780` 变为 `...c7c0`，差值为 `0x40`。
- exploit 找到共享页面，成功写入 `/etc/passwd`，guest 中 `su` 得到 root，并读出 `flag{PageJack_Demo_Flag_ZJU_RKP}`。
- 自动运行日志记录了第 1 次布局未命中、第 2 次端到端成功。现有记录不是多轮成功率评估。

QEMU 参数包含 `nokaslr` 和 `page_alloc.shuffle=0`。本项目没有据此评估 KASLR 防护，也没有对其他内核版本或真实主机做验证。

## 文件说明

| 路径 | 内容 |
| --- | --- |
| `challenge/exp.c` | exploit C 源码；可运行静态二进制随 Release 提供 |
| `kernel/patches/` | 针对上游 Linux 6.5-rc1 的最小教学补丁 |
| `kernel/kernel.config-debug` | 调试内核配置，包含教学漏洞开关 |
| `kernel/kernel.config-author` | 目录中作者基线内核所用配置 |
| `build_debug_kernel.sh` | 获取固定版本源码、应用补丁并在 Podman 中构建 |
| `run_auto.sh`, `run_gdb.sh` | 自动 exploit 和交互调试 QEMU 启动器 |
| `gdb-pagejack.gdb` | GDB 断点及源码路径设置 |
| `pack_rootfs.py` | 由解包 initramfs 重新打包 CPIO 的工具 |
| `lab.md` | 面向初学者的 buddy、页引用、pipe 和页面级 UAF 讲解 |
| `gdb_verification_guide.md` | GDB/QEMU 逐步观测记录 |
| `report/` | 中文复现报告、PDF 与截图证据 |
| `report/evidence/` | QEMU/GDB 文本记录和附件哈希记录 |

Linux 源码、编译目录、内核映像、initramfs 与 exploit 二进制属于大体积构建/运行附件，使用 GitHub Release 保存。源码目录会在需要时由构建脚本获取。

## 从源码构建

构建调试内核需要 Podman、Git、网络连接以及足够的磁盘空间和内存。脚本会检出上游 Linux tag `v6.5-rc1`（commit `06c2afb862f9da8dc5efa4b6076a0e48c3fbaaa5`），应用 `kernel/patches/` 中的本实验补丁，然后在 Ubuntu 22.04 容器内构建：

```bash
./build_debug_kernel.sh
```

它生成 `kernel/vmlinux`、`kernel/bzImage-debug` 和更新后的 `kernel/kernel.config-debug`。原论文提供的基线文件 `bzImage-author` / `vmlinux-author.stripped` 不与这个教学构建配对；上游 Linux 6.5-rc1 也不包含作者配置中的下游选项 `CONFIG_SLAB_VIRTUAL`。

重新编译 guest exploit：

```bash
gcc -O2 -static -no-pie -masm=intel -o challenge/exp challenge/exp.c
```

重新打包 rootfs 时，先下载 Release 并解包 CPIO，再运行：

```bash
mkdir -p rootfs/gdb-unpacked rootfs/auto-unpacked
(cd rootfs/gdb-unpacked && cpio -idm --no-absolute-filenames < ../rootfs-gdb.cpio)
(cd rootfs/auto-unpacked && cpio -idm --no-absolute-filenames < ../rootfs-auto.cpio)
python3 ./pack_rootfs.py rootfs/gdb-unpacked rootfs/rootfs-gdb.cpio --force
python3 ./pack_rootfs.py rootfs/auto-unpacked rootfs/rootfs-auto.cpio --force
```

## 实验边界

运行包中的故意易受攻击内核只用于本机隔离的 QEMU guest。不要在宿主机上启动、安装或部署它。exploit 会在 guest 内修改 `/etc/passwd`；QEMU 只挂载随附件提供的只读 flag 镜像。请勿把该内核配置用于日常或生产系统。

## 参考资料

- Jiayi Hu、Zhiyun Qian、Jinmeng Zhou、Qi Tang、Wenbo Shen，[*PageJack: A Powerful Exploit Technique With Page-Level UAF*](https://i.blackhat.com/BH-US-24/Presentations/US24-Qian-PageJack-A-Powerful-Exploit-Technique-With-Page-Level-UAF-Thursday.pdf)，Black Hat USA 2024。
- Quarkslab，[*PageJack in Action: CVE-2022-0995 exploit*](https://blog.quarkslab.com/pagejack-in-action-cve-2022-0995-exploit.html)，用于对照该 demo 的利用链与内核对象行为。
- 上游内核基线：[Linux v6.5-rc1](https://github.com/torvalds/linux/tree/v6.5-rc1)。
