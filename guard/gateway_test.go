package main

import (
	"strings"
	"testing"
)

func TestArpResolved(t *testing.T) {
	const table = `IP address       HW type     Flags       HW address            Mask     Device
192.168.64.1     0x1         0x2         c2:c7:db:51:9a:64     *        eth0
192.168.64.9     0x1         0x0         00:00:00:00:00:00     *        eth0
192.168.64.10    0x1         0x6         c2:c7:db:51:9a:65     *        eth0
`
	cases := map[string]bool{
		"192.168.64.1":  true,  // 解析出来了
		"192.168.64.9":  false, // 问过没人答（incomplete）
		"192.168.64.10": true,  // 带别的标志也算
		"192.168.64.11": false, // 表里没有
		"192.168.64":    false, // 不能按前缀算
	}
	for ip, want := range cases {
		if got := arpResolved(strings.NewReader(table), ip); got != want {
			t.Errorf("%s：得到 %v，应为 %v", ip, got, want)
		}
	}
}
