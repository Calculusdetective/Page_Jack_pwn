# 内核教学补丁

`0001-pagejack-lab-vuln.patch` 针对上游 Linux `v6.5-rc1`（commit `06c2afb862f9da8dc5efa4b6076a0e48c3fbaaa5`）。它新增默认关闭的 `CONFIG_PAGEJACK_LAB_VULN` 选项；仅在该选项开启时，`watch_queue_set_filter()` 才会跳过未知 notification type 的检查。

这项改动是为了在隔离 QEMU guest 中复现已修复的 OOB 写入利用路径。补丁刻意恢复易受攻击的行为，绝不可在宿主机或生产内核配置中启用。

直接从仓库根目录构建时，`build_debug_kernel.sh` 会检出对应上游 tag 并应用补丁。无需将 1.5 GB 的完整内核源码放入本仓库。
