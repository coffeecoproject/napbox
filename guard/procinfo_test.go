package main

import "testing"

func TestInServiceCgroup(t *testing.T) {
	cases := []struct {
		content, service string
		want             bool
	}{
		{"0::/../web\n", "web", true},
		{"0::/../web/init.scope\n", "web", true},
		{"0::/../web-admin\n", "web", false},
		{"0::/../db\n", "web", false},
		{"0::/\n", "web", false},
		{"0::/../other/web\n", "web", false},
		{"", "web", false},
	}
	for _, c := range cases {
		if got := inServiceCgroup(c.content, c.service); got != c.want {
			t.Errorf("inServiceCgroup(%q, %q) = %v，应该是 %v", c.content, c.service, got, c.want)
		}
	}
}

func TestIsContainerInit(t *testing.T) {
	cases := []struct {
		content string
		want    bool
	}{
		{"Name:\tsleep\nNSpid:\t412\t1\nPPid:\t1\n", true},
		// 容器里 exec 出来的命令
		{"Name:\tsh\nNSpid:\t530\t27\n", false},
		// 虚拟机自己的进程
		{"Name:\tvminitd\nNSpid:\t1\n", false},
		// 容器里又开了一层进程命名空间，里面的 1 号进程
		{"Name:\tinner\nNSpid:\t600\t40\t1\n", false},
		{"Name:\tsleep\n", false},
	}
	for _, c := range cases {
		if got := isContainerInit(c.content); got != c.want {
			t.Errorf("isContainerInit(%q) = %v，应该是 %v", c.content, got, c.want)
		}
	}
}
