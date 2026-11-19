//go:build linux

package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// 服务连本机程序（x-napbox.host_services）的虚拟机这一头：在网桥地址上听点了名的端口，服务连
// host.docker.internal:端口（hosts 里指到网桥地址）进来，经 vsock 连到宿主机上 napboxd 听的端口，由它在本机连 127.0.0.1:端口
// （NapboxRuntime 的 HostServices）。不经过出网规则：服务到网桥地址是进虚拟机自己，不是转发（egress.go 只管转发）。
//
// 听哪些端口、听在哪个地址由 napboxd 用环境变量给（GuardContainer.hostServicesEnvironment），没给就不听。
// 起的时候网桥可能还没建（第一个服务接上来时才建，network.go），所以用 IP_FREEBIND 先占住地址。

// 和 HostServices.vsockPort 一致
func hostServiceVsockPort(port int) uint32 { return 0x3000_0000 + uint32(port) }

// NAPBOX_HOST_SERVICES 是空格分开的端口号
func parseHostServices(ports, address string) ([]string, error) {
	if ports == "" {
		return nil, nil
	}
	if net.ParseIP(address).To4() == nil {
		return nil, fmt.Errorf("NAPBOX_HOST_ADDRESS %q 不是 IPv4 地址", address)
	}
	var listen []string
	for _, p := range strings.Fields(ports) {
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 65535 {
			return nil, fmt.Errorf("NAPBOX_HOST_SERVICES 里的 %q 不是端口号", p)
		}
		listen = append(listen, net.JoinHostPort(address, p))
	}
	return listen, nil
}

func serveHostServices() error {
	listen, err := parseHostServices(os.Getenv("NAPBOX_HOST_SERVICES"), os.Getenv("NAPBOX_HOST_ADDRESS"))
	if err != nil || len(listen) == 0 {
		return err
	}
	config := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var set error
		if err := c.Control(func(fd uintptr) { set = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_FREEBIND, 1) }); err != nil {
			return err
		}
		return set
	}}
	errs := make(chan error, len(listen))
	for _, address := range listen {
		listener, err := config.Listen(context.Background(), "tcp4", address)
		if err != nil {
			return fmt.Errorf("连本机程序：听不了 %s：%w", address, err)
		}
		_, port, _ := net.SplitHostPort(address)
		n, _ := strconv.Atoi(port)
		go func() { errs <- acceptHostService(listener, hostServiceVsockPort(n)) }()
	}
	return <-errs
}

func acceptHostService(listener net.Listener, vsockPort uint32) error {
	for {
		service, err := listener.Accept()
		if err != nil {
			return fmt.Errorf("连本机程序：接受连接失败：%w", err)
		}
		go func() {
			defer service.Close()
			host, err := dialHost(vsockPort)
			if err != nil {
				return
			}
			defer host.Close()
			pipeHalves(service.(*net.TCPConn), host)
		}()
	}
}

// 连宿主机（napboxd）在 vsock 上听的端口。napboxd 不放行（出网模式 none）时接下来就断开
func dialHost(port uint32) (*os.File, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	if err := unix.Connect(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_HOST, Port: port}); err != nil {
		unix.Close(fd)
		return nil, err
	}
	// 非阻塞的 fd 交给 os.File 后由 Go 的 netpoller 等待，不占线程
	if err := unix.SetNonblock(fd, true); err != nil {
		unix.Close(fd)
		return nil, err
	}
	return os.NewFile(uintptr(fd), "vsock"), nil
}

// vsock 的 os.File 没有 CloseWrite，直接 shutdown 发送那半边
func closeWrite(f *os.File) {
	if raw, err := f.SyscallConn(); err == nil {
		raw.Control(func(fd uintptr) { unix.Shutdown(int(fd), unix.SHUT_WR) })
	}
}

// 两头互相转发，一头不再发了就关掉另一头的发送那半边，两个方向都结束才返回
func pipeHalves(a *net.TCPConn, b *os.File) {
	done := make(chan struct{}, 2)
	go func() {
		io.Copy(b, a)
		closeWrite(b)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(a, b)
		a.CloseWrite()
		done <- struct{}{}
	}()
	<-done
	<-done
}
