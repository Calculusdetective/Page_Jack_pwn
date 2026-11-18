set pagination off
set confirm off
set breakpoint pending on
set disassembly-flavor intel
set disassemble-next-line on
set print pretty on
set substitute-path /work/learning_materials/pagejack/reproduction/kernel-src ./kernel/source
file ./kernel/vmlinux
target remote :1234

break kernel/source/linux-6.5-rc1/kernel/watch_queue.c:309
continue

# Leave the debugger at the real function-entry stop.  The later commands
# used for the screenshots were typed into this same GDB terminal.
