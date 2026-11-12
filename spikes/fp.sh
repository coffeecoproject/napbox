#!/bin/bash
# 每个 container 虚拟机的内存占用：按启动时间把 VirtualMachine 进程对应到 runtime 进程的容器名
for rt in $(pgrep -f container-runtime-linux); do
  name=$(ps -o args= -p $rt | grep -o -E 'containers/[^/ ]+' | head -1 | cut -d/ -f2)
  vm=$(pgrep -f com.apple.Virtualization.VirtualMachine | while read v; do [ $v -gt $rt ] && [ $v -le $((rt+5)) ] && echo $v; done | head -1)
  [ -n "$vm" ] && printf '%-14s %s\n' "$name" "$(footprint $vm 2>/dev/null | grep -o 'Footprint: [0-9]* MB' | grep -o '[0-9]* MB')"
done | sort
