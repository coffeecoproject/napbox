//go:build linux

// napbox-guard：每个环境里的网络小容器（DESIGN.md 第 6、7 节）。napboxd 把它直接写进一个根文件系统，不用镜像。
// 它留在虚拟机自己的网络里，每个服务的容器各有各的网络（network.go）：出网规则加在虚拟机替服务转发的那条路上，
// 转发端口时从这里连服务的地址。
//
//	napbox-guard              当容器的 1 号进程：转发端口连接（relay.go）、发文件变化通知（notify.go），收养并回收孤儿进程，收到 SIGTERM/SIGINT 退出
//	napbox-guard egress open <DNS 服务器> [网段或地址...] | none   换掉所有服务的出网规则（一次事务，要 NET_ADMIN）
//	napbox-guard listening <服务>   列出这个服务正在监听的 TCP 端口，一行一个
//	napbox-guard sync         把虚拟机的文件系统刷到磁盘
//	napbox-guard gateway <网关>   网关在不在这台虚拟机的网络上（gateway.go），起环境和构建时先查
//	napbox-guard populate <服务的根文件系统> <卷在服务里的路径> <卷>   卷是空的就带上镜像里那个目录的内容（populate.go）
//	napbox-guard rebind (<服务> <文件在这里的路径> <文件在服务里的路径> rw|ro)...   宿主机把挂进服务的单个文件换掉了，让服务挂上现在这个（rebind.go）
//
// 同一个程序改名叫 napbox-runc 时是另一个用途：垫在 vminitd 和 runc 中间，建服务的容器时给它接上自己的网络（runtime.go）。
package main

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

func main() {
	args := os.Args[1:]
	executable, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if filepath.Base(executable) == runtimeProgram {
		runAsRuntime(executable, args)
		return
	}
	switch {
	case len(args) == 0:
		serve()
	case len(args) >= 2 && args[0] == "egress":
		err = applyEgress(args[1], args[2:])
	case len(args) == 2 && args[0] == "listening":
		err = printListening(os.Stdout, args[1])
	case len(args) == 2 && args[0] == "gateway":
		err = checkGateway(args[1])
	case len(args) == 1 && args[0] == "sync":
		syscall.Sync()
	case len(args) == 4 && args[0] == "populate":
		err = populateVolume(args[1], args[2], args[3])
	case len(args) >= 1 && args[0] == "rebind":
		err = rebindFiles(args[1:], os.Stdout)
	default:
		err = fmt.Errorf("用法：napbox-guard [egress open <DNS 服务器> [网段或地址...] | egress none | listening <服务> | gateway <网关> | sync | populate <根文件系统> <路径> <卷> | rebind (<服务> <来源> <路径> rw|ro)...]")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func serve() {
	// 这两个断了环境就没法用了：退出，让 napboxd 按服务退出处理，不留一个看起来正常的环境
	for _, listen := range []func() error{serveRelay, serveNotify} {
		go func() {
			if err := listen(); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}()
	}
	signals := make(chan os.Signal, 8)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGCHLD)
	for s := range signals {
		if s != syscall.SIGCHLD {
			os.Exit(0)
		}
		for {
			pid, err := syscall.Wait4(-1, nil, syscall.WNOHANG, nil)
			if pid <= 0 || err != nil {
				break
			}
		}
	}
}
