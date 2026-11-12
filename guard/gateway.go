package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// checkGateway：网关在不在这台虚拟机的网络上（DESIGN.md 第 2 节「和苹果 container 同时开着」）。napboxd 给虚拟机
// 写死了宿主机那个网段的地址和网关；系统把虚拟机放进别的网段时，网关就不在同一个网络上，DNS 和出网都不通。
// 往网关发一个 UDP 包让内核去做 ARP，再看 /proc/net/arp 里网关有没有解析出 MAC。只看二层：不经宿主机的 DNS
// 和 Clash，答得快、不误判。
func checkGateway(gateway string) error {
	ip := net.ParseIP(gateway).To4()
	if ip == nil {
		return fmt.Errorf("网关 %q 不是 IPv4 地址", gateway)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		// 9 是 discard 端口：包本身没人要，只为让内核去解析网关
		if conn, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: ip, Port: 9}); err == nil {
			_, _ = conn.Write([]byte{0})
			conn.Close()
		}
		table, err := os.Open("/proc/net/arp")
		if err != nil {
			return err
		}
		found := arpResolved(table, ip.String())
		table.Close()
		if found {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("3 秒内 ARP 没有应答，它不在这台虚拟机的网络上")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// arpResolved：/proc/net/arp 里这个地址已经解析出 MAC（Flags 带 ATF_COM 0x2）
//
//	IP address       HW type     Flags       HW address            Mask     Device
//	192.168.64.1     0x1         0x2         c2:c7:db:51:9a:64     *        eth0
func arpResolved(table io.Reader, ip string) bool {
	scanner := bufio.NewScanner(table)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 || fields[0] != ip {
			continue
		}
		flags, err := strconv.ParseUint(strings.TrimPrefix(fields[2], "0x"), 16, 32)
		if err == nil && flags&0x2 != 0 {
			return true
		}
	}
	return false
}
