package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// vminitd 叫 runc 时的参数（Containerization 0.53.0 的 Runc.swift），在虚拟机里实际看到的样子
var createArgs = []string{
	"--log", "/run/runc-log-6F1C.json", "--log-format", "json", "--root", "/run/runc",
	"create", "--pid-file", "/run/container/db/runc-pid", "--bundle", "/run/container/db", "db",
}

func TestRuncArguments(t *testing.T) {
	if got := runcSubcommand(createArgs); got != "create" {
		t.Fatalf("子命令：%q", got)
	}
	// 全局参数的值长得像子命令也不能认错
	if got := runcSubcommand([]string{"--root", "create", "--debug", "start", "db"}); got != "start" {
		t.Fatalf("子命令：%q", got)
	}
	if got := runcSubcommand([]string{"--version"}); got != "" {
		t.Fatalf("没有子命令时：%q", got)
	}
	for name, want := range map[string]string{
		"--bundle": "/run/container/db", "--pid-file": "/run/container/db/runc-pid",
		"--log": "/run/runc-log-6F1C.json", "--root": "/run/runc", "--console-socket": "",
	} {
		if got := runcFlag(createArgs, name); got != want {
			t.Fatalf("%s：%q", name, got)
		}
	}
	if got := runcFlag([]string{"create", "--bundle=/b", "db"}, "--bundle"); got != "/b" {
		t.Fatalf("等号写法：%q", got)
	}
}

func TestWithNetworkNamespace(t *testing.T) {
	// 大数字（内存上限）和别的字段要原样留着
	config := `{"ociVersion":"1.1.0","process":{"args":["postgres"]},
		"linux":{"resources":{"memory":{"limit":9223372036854771712}},"namespaces":[{"type":"pid"},{"type":"mount"}]}}`
	out, err := withNetworkNamespace([]byte(config))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), "9223372036854771712") {
		t.Fatalf("大数字变了：%s", out)
	}
	var spec struct {
		Process struct{ Args []string }
		Linux   struct{ Namespaces []map[string]string }
	}
	if err := json.Unmarshal(out, &spec); err != nil {
		t.Fatal(err)
	}
	want := []map[string]string{{"type": "pid"}, {"type": "mount"}, {"type": "network"}}
	if !reflect.DeepEqual(spec.Linux.Namespaces, want) || !reflect.DeepEqual(spec.Process.Args, []string{"postgres"}) {
		t.Fatalf("改完是：%s", out)
	}

	// 已经有网络命名空间、没有 linux 这一段：都是没料到的配置，报错
	for _, bad := range []string{
		`{"linux":{"namespaces":[{"type":"network","path":"/proc/1/ns/net"}]}}`,
		`{"process":{}}`,
		`not json`,
	} {
		if _, err := withNetworkNamespace([]byte(bad)); err == nil {
			t.Fatalf("应该报错：%s", bad)
		}
	}
}

func TestNetworkConfig(t *testing.T) {
	config, err := parseNetworkConfig([]byte(`{"gateway":"10.88.0.1","prefix":24,"services":{"db":"10.88.0.2","web":"10.88.0.3"}}`))
	if err != nil {
		t.Fatal(err)
	}
	network, err := config.network("web")
	if err != nil {
		t.Fatal(err)
	}
	prefix, _ := network.mask.Size()
	if network.address.String() != "10.88.0.3" || network.gateway.String() != "10.88.0.1" || prefix != 24 ||
		len(network.address) != 4 || len(network.gateway) != 4 {
		t.Fatalf("%+v", network)
	}
	// 没列出来的服务不给地址：napboxd 和这里对不上时报错，不让容器用别的网络起来
	if _, err := config.network("cache"); err == nil || !strings.Contains(err.Error(), "cache") {
		t.Fatalf("没列出来的服务：%v", err)
	}

	for _, bad := range []string{
		`{"gateway":"10.88.0.1","prefix":24,"services":{"db":"10.89.0.2"}}`, // 不在网段里
		`{"gateway":"10.88.0.1","prefix":24,"services":{"db":"10.88.0.1"}}`, // 和网关撞了
		`{"gateway":"10.88.0.1","prefix":24,"services":{"db":"fd00::2"}}`,   // 不是 IPv4
		`{"gateway":"","prefix":24,"services":{"db":"10.88.0.2"}}`,
		`{"gateway":"10.88.0.1","prefix":0,"services":{"db":"10.88.0.2"}}`,
	} {
		config, err := parseNetworkConfig([]byte(bad))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := config.network("db"); err == nil {
			t.Fatalf("应该报错：%s", bad)
		}
	}
	if _, err := parseNetworkConfig([]byte(`[]`)); err == nil {
		t.Fatal("不是对象应该报错")
	}
}
