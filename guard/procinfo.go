package main

import "strings"

// 读 /proc/<进程>/cgroup 和 status，认出某个服务容器的 1 号进程（rebind.go 用）。

// cgroup 文件的内容是不是说这个进程在这个服务的容器里。
// 虚拟机里只有 cgroup v2，一行 "0::<路径>"。每个容器的 cgroup 是 /container/pod/<pod>/<容器名>，各有自己的 cgroup
// 命名空间（Containerization 的 LinuxPod），所以从网络小容器里看，别的容器是 "/../<容器名>"，
// 它在自己下面又分了组的话后面还有一段。
func inServiceCgroup(content, service string) bool {
	for _, line := range strings.Split(content, "\n") {
		path, ok := strings.CutPrefix(line, "0::")
		if !ok {
			continue
		}
		own := "/../" + service
		return path == own || strings.HasPrefix(path, own+"/")
	}
	return false
}

// status 文件的内容是不是说这个进程是一个容器的 1 号进程：NSpid 一行列出它在每一层进程命名空间里的进程号，
// 容器的 1 号进程是两层（虚拟机里的号、容器里的 1）。容器里用 exec 跑的命令和它们的子进程都不是 1。
func isContainerInit(content string) bool {
	for _, line := range strings.Split(content, "\n") {
		rest, ok := strings.CutPrefix(line, "NSpid:")
		if !ok {
			continue
		}
		numbers := strings.Fields(rest)
		return len(numbers) == 2 && numbers[1] == "1"
	}
	return false
}
