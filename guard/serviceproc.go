//go:build linux

package main

import (
	"fmt"
	"io"
	"os"
	"strconv"

	"golang.org/x/sys/unix"
)

// 从网络小容器里找到某个服务的容器：换单个文件的挂载（rebind.go）要进它的挂载命名空间，
// 查监听端口（listening_linux.go）要看它的网络命名空间。两样都从它的 1 号进程拿。

// 虚拟机的 /proc 挂在这（napboxd 里的 GuardContainer）：这个容器自己的 /proc 里看不到服务的进程
const vmProc = "/napbox-vmproc"

// 打开服务容器 1 号进程在虚拟机 /proc 里的目录，用完要关。之后都从这个目录往下读：
// 读到一半进程没了、进程号给了别人，读到的也不会是别人的
func openServiceInit(service string) (int, error) {
	entries, err := os.ReadDir(vmProc)
	if err != nil {
		return -1, err
	}
	for _, entry := range entries {
		if _, err := strconv.Atoi(entry.Name()); err != nil {
			continue
		}
		process, err := unix.Open(vmProc+"/"+entry.Name(), unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
		if err != nil {
			continue
		}
		cgroup, _ := readAt(process, "cgroup")
		status, _ := readAt(process, "status")
		if inServiceCgroup(cgroup, service) && isContainerInit(status) {
			return process, nil
		}
		unix.Close(process)
	}
	return -1, fmt.Errorf("虚拟机里找不到 %s 的进程", service)
}

func readAt(directory int, name string) (string, error) {
	fd, err := unix.Openat(directory, name, unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	file := os.NewFile(uintptr(fd), name)
	defer file.Close()
	content, err := io.ReadAll(file)
	return string(content), err
}
