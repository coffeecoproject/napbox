//go:build ignore

// test/vm.test.ts 用的服务（Linux arm64，挂进容器运行），试端口转发的各种情况。
package main

import (
	"io"
	"net"
)

func serve(address string, handle func(*net.TCPConn)) {
	listener, err := net.Listen("tcp", address)
	if err != nil {
		panic(err)
	}
	for {
		connection, err := listener.Accept()
		if err != nil {
			panic(err)
		}
		go func() {
			defer connection.Close()
			handle(connection.(*net.TCPConn))
		}()
	}
}

func main() {
	// 回显，对方半关闭后写完再关
	go serve(":8080", func(c *net.TCPConn) {
		io.Copy(c, c)
		c.CloseWrite()
	})
	// 告诉对方服务看到的来源地址
	go serve(":8081", func(c *net.TCPConn) {
		host, _, _ := net.SplitHostPort(c.RemoteAddr().String())
		c.Write([]byte(host))
	})
	// 发 64MB 内容固定的数据
	go serve(":8082", func(c *net.TCPConn) {
		block := make([]byte, 64*1024)
		for i := range block {
			block[i] = byte(i * 7)
		}
		for i := 0; i < 1024; i++ {
			if _, err := c.Write(block); err != nil {
				return
			}
		}
	})
	// 只听 127.0.0.1：和 Docker 一样，从宿主机转发不过来
	go serve("127.0.0.1:8083", func(c *net.TCPConn) { c.Write([]byte("loopback")) })
	// 接受了但一直不读
	serve(":8084", func(c *net.TCPConn) { select {} })
}
