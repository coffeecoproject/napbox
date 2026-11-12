package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
)

// 垫在 runc 前面那一层（runtime.go）用到的、不碰系统的部分：看懂 vminitd 给 runc 的参数、改容器的 OCI 配置、读 net.json。

// runc 的全局参数里这几个后面跟一个值，其余是开关
var runcGlobalsWithValue = map[string]bool{"--root": true, "--log": true, "--log-format": true, "--rootless": true}

// 子命令：全局参数后面第一个不是参数的。没有就是空的
func runcSubcommand(args []string) string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			return a
		}
		if runcGlobalsWithValue[a] {
			i++
		}
	}
	return ""
}

// 参数 name 的值，"--name 值" 和 "--name=值" 两种写法都认。没有就是空的
func runcFlag(args []string, name string) string {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1]
		}
		if value, ok := strings.CutPrefix(a, name+"="); ok {
			return value
		}
	}
	return ""
}

// 在容器的 OCI 配置（config.json）的 linux.namespaces 里加一项 network：不带 path，runc 就给这个容器新建一个网络命名空间。
// 别的内容原样留着，数字不经过浮点数。
func withNetworkNamespace(config []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(config))
	decoder.UseNumber()
	var spec map[string]any
	if err := decoder.Decode(&spec); err != nil {
		return nil, err
	}
	linux, ok := spec["linux"].(map[string]any)
	if !ok {
		return nil, errors.New("没有 linux 这一段")
	}
	namespaces, _ := linux["namespaces"].([]any)
	for _, n := range namespaces {
		if m, ok := n.(map[string]any); ok && m["type"] == "network" {
			return nil, errors.New("已经有 network 命名空间了")
		}
	}
	linux["namespaces"] = append(namespaces, map[string]any{"type": "network"})
	return json.Marshal(spec)
}

// net.json：napboxd 写在这个程序旁边（NapboxRuntime 的 EnvironmentLayout.runtimeDisk）。
// 网关是网桥在虚拟机里的地址，也是每个服务的默认路由；services 是每个服务的地址。
type networkConfig struct {
	Gateway  string            `json:"gateway"`
	Prefix   int               `json:"prefix"`
	Services map[string]string `json:"services"`
}

// 服务网络：网关、掩码、这个服务的地址，都是 4 字节的 IPv4
type serviceNetwork struct {
	gateway net.IP
	mask    net.IPMask
	address net.IP
}

// 这个服务在 net.json 里的地址。没有它就是 napboxd 和这里对不上，报错，不让它用别的网络起来
func (c networkConfig) network(service string) (serviceNetwork, error) {
	gateway := net.ParseIP(c.Gateway).To4()
	if gateway == nil || c.Prefix < 8 || c.Prefix > 30 {
		return serviceNetwork{}, fmt.Errorf("net.json 的网关 %q/%d 不对", c.Gateway, c.Prefix)
	}
	text, ok := c.Services[service]
	if !ok {
		return serviceNetwork{}, fmt.Errorf("net.json 里没有 %s 的地址", service)
	}
	address := net.ParseIP(text).To4()
	mask := net.CIDRMask(c.Prefix, 32)
	if address == nil || !address.Mask(mask).Equal(gateway.Mask(mask)) || address.Equal(gateway) {
		return serviceNetwork{}, fmt.Errorf("net.json 里 %s 的地址 %q 不在 %s/%d 里", service, text, c.Gateway, c.Prefix)
	}
	return serviceNetwork{gateway: gateway, mask: mask, address: address}, nil
}

func parseNetworkConfig(content []byte) (networkConfig, error) {
	var config networkConfig
	if err := json.Unmarshal(content, &config); err != nil {
		return networkConfig{}, fmt.Errorf("net.json：%w", err)
	}
	return config, nil
}
