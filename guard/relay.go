//go:build linux

package main

import (
	"fmt"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// 端口转发的虚拟机这一头：napboxd 从 vsock 连进来，所有转发的连接都复用这一条（mux.go）。
// 走 vsock 不经过本地网络：登录项运行的 napboxd 直接连虚拟机的 IP 要用户批准 macOS 的
// “本地网络”权限，开着 Clash 时还可能被它接管。目标是服务自己的地址（network.go），从虚拟机的网络连过去：
// 服务看到的和 Docker 端口转发一样不是本机连接，pg_hba 这类规则不会因此放行。
const relayPort = 5300

func serveRelay() error {
	return serveVsock(relayPort, func(host *os.File) {
		serveMux(host, func(target string) (net.Conn, error) { return net.Dial("tcp", target) })
	})
}

// 在 vsock 端口上接受 napboxd 的连接，每条连接一个 goroutine。监听出错才返回。
func serveVsock(port uint32, handle func(*os.File)) error {
	listener, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("建不了 vsock：%w", err)
	}
	if err := unix.Bind(listener, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		return fmt.Errorf("绑不了 vsock 端口 %d：%w", port, err)
	}
	if err := unix.Listen(listener, 1024); err != nil {
		return fmt.Errorf("监听不了 vsock：%w", err)
	}
	for {
		connection, _, err := unix.Accept4(listener, unix.SOCK_CLOEXEC|unix.SOCK_NONBLOCK)
		if err == unix.EINTR || err == unix.ECONNABORTED {
			continue
		}
		if err != nil {
			return fmt.Errorf("接受 vsock 连接失败：%w", err)
		}
		// 非阻塞的 fd 交给 os.File 后由 Go 的 netpoller 等待，不占线程
		go func() {
			host := os.NewFile(uintptr(connection), "vsock")
			defer host.Close()
			handle(host)
		}()
	}
}
