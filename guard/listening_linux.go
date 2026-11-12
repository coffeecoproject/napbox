package main

import (
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"

	"golang.org/x/sys/unix"
)

// printListening 列出这个服务正在监听的 TCP 端口（IPv4 和 IPv6），一行一个，从小到大。
// 每个服务有自己的网络，监听的端口只在它自己的网络命名空间里看得到：/proc/<进程>/net 给的是那个进程所在网络的内容，
// 所以读服务 1 号进程的。
func printListening(w io.Writer, service string) error {
	process, err := openServiceInit(service)
	if err != nil {
		return err
	}
	defer unix.Close(process)
	ports := map[int]bool{}
	for _, name := range []string{"net/tcp", "net/tcp6"} {
		content, err := readAt(process, name)
		if errors.Is(err, unix.ENOENT) && name == "net/tcp6" {
			continue // 内核没开 IPv6
		}
		if err != nil {
			return fmt.Errorf("读 %s 的 %s：%w", service, name, err)
		}
		found, err := listeningPorts(strings.NewReader(content))
		if err != nil {
			return fmt.Errorf("%s 的 %s：%w", service, name, err)
		}
		for _, p := range found {
			ports[p] = true
		}
	}
	sorted := make([]int, 0, len(ports))
	for p := range ports {
		sorted = append(sorted, p)
	}
	sort.Ints(sorted)
	for _, p := range sorted {
		fmt.Fprintln(w, p)
	}
	return nil
}
