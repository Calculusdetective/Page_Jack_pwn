set pagination off
set confirm off
set breakpoint pending on
set disassembly-flavor intel
set disassemble-next-line on
set print pretty on

# Resolve the source paths recorded in either the original image or a rebuild.
set substitute-path /work/learning_materials/pagejack/reproduction/kernel-src ./kernel/source/linux-6.5-rc1
set substitute-path /work/kernel/source/linux-6.5-rc1 ./kernel/source/linux-6.5-rc1
file ./kernel/vmlinux
target remote :1234

break watch_queue_set_filter
break alloc_pipe_info
break pipe_release

printf "PageJack GDB target connected.  Use 'continue' to boot or resume.\n"
