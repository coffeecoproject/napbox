//go:build linux

// 实验用：垫在苹果的 vminitd 和 runc 中间的一层。vminitd 以为自己在叫 runc，其实叫的是它。
// 除了 create 以外的命令原样转给旁边的 runc；create 时如果这个容器在 net.json 里有地址，
// 就给它加一个自己的网络命名空间，建好以后用一对 veth 接到虚拟机里的网桥上、配好地址和默认路由。
// 这些都要在 create 返回之前做完：vminitd 接着就会叫 start，服务一起来网络已经是好的。
//
// 另外几个实验用的小命令：hold（什么都不做，给装它的容器当主进程）、
// egress-none / egress-open <网桥名>（在转发路径上挡住/放开服务出网，验证出网规则还管得住）。
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
	"github.com/mdlayher/netlink"
	"golang.org/x/sys/unix"
)

const logPath = "/run/nsrt.log"

// net.json：网桥、网关、掩码长度，和哪些容器要单独的网络、各自什么地址
type netConfig struct {
	Bridge     string            `json:"bridge"`
	Gateway    string            `json:"gateway"`
	Prefix     int               `json:"prefix"`
	Containers map[string]string `json:"containers"`
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "hold":
			ch := make(chan os.Signal, 1)
			signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
			<-ch
			return
		case "egress-none", "egress-open":
			if len(args) != 2 {
				exitOn(errors.New("用法：egress-none|egress-open <网桥名>"))
			}
			exitOn(egress(args[1], args[0] == "egress-none"))
			return
		}
	}
	if subcommand(args) != "create" {
		runc := realRunc()
		exitOn(syscall.Exec(runc, append([]string{runc}, args...), os.Environ()))
	}
	exitOn(create(args))
}

func exitOn(err error) {
	if err != nil {
		logf("失败：%v", err)
		fmt.Fprintln(os.Stderr, "nsrt:", err)
		os.Exit(1)
	}
}

func logf(format string, a ...any) {
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, format+"\n", a...)
}

func selfDir() string {
	if exe, err := os.Executable(); err == nil {
		return filepath.Dir(exe)
	}
	return filepath.Dir(os.Args[0])
}

func realRunc() string { return filepath.Join(selfDir(), "runc") }

// runc 的全局参数里这几个后面跟一个值，其余是开关；第一个不是参数的就是子命令
var globalsWithValue = map[string]bool{"--root": true, "--log": true, "--log-format": true}

func subcommand(args []string) string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			return a
		}
		if globalsWithValue[a] {
			i++
		}
	}
	return ""
}

func flagValue(args []string, name string) string {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1]
		}
		if strings.HasPrefix(a, name+"=") {
			return a[len(name)+1:]
		}
	}
	return ""
}

func create(args []string) error {
	id := args[len(args)-1]
	bundle := flagValue(args, "--bundle")
	pidFile := flagValue(args, "--pid-file")
	logf("create %s：参数 %q", id, args)

	var cfg netConfig
	raw, err := os.ReadFile(filepath.Join(selfDir(), "net.json"))
	if err != nil {
		return err
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return fmt.Errorf("net.json：%w", err)
	}
	address, isolated := cfg.Containers[id]
	if isolated {
		if bundle == "" || pidFile == "" {
			return fmt.Errorf("create 没带 --bundle 或 --pid-file：%q", args)
		}
		if err := addNetworkNamespace(filepath.Join(bundle, "config.json")); err != nil {
			return fmt.Errorf("改 config.json：%w", err)
		}
	}

	runc := realRunc()
	cmd := exec.Command(runc, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			logf("create %s：runc 退出码 %d", id, exit.ExitCode())
			os.Exit(exit.ExitCode())
		}
		return err
	}
	if !isolated {
		logf("create %s：不在 net.json 里，留在共用的网络", id)
		return nil
	}

	started := time.Now()
	text, err := os.ReadFile(pidFile)
	if err != nil {
		return err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(text)))
	if err != nil {
		return fmt.Errorf("pid 文件内容 %q", text)
	}
	if err := wire(cfg, id, address, pid); err != nil {
		// 网络没接上就不能让它起来：把刚建的容器删掉，让 vminitd 看到失败
		del := exec.Command(runc, "--root", flagValue(args, "--root"), "delete", "--force", id)
		_ = del.Run()
		return fmt.Errorf("给 %s 接网络：%w", id, err)
	}
	logf("create %s：pid %d，地址 %s，接网络用了 %.1f 毫秒", id, pid, address, float64(time.Since(started).Microseconds())/1000)
	return nil
}

// addNetworkNamespace 在 OCI 配置的 linux.namespaces 里加一项 network（没有 path，runc 就新建一个）
func addNetworkNamespace(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var spec map[string]any
	if err := dec.Decode(&spec); err != nil {
		return err
	}
	linux, ok := spec["linux"].(map[string]any)
	if !ok {
		return errors.New("没有 linux 这一段")
	}
	namespaces, _ := linux["namespaces"].([]any)
	for _, n := range namespaces {
		if m, ok := n.(map[string]any); ok && m["type"] == "network" {
			return errors.New("已经有 network 命名空间了")
		}
	}
	linux["namespaces"] = append(namespaces, map[string]any{"type": "network"})
	out, err := json.Marshal(spec)
	if err != nil {
		return err
	}
	return os.WriteFile(path, out, 0o644)
}

// ---- 接网络 ----

const vethInfoPeer = 1 // linux/veth.h 的 VETH_INFO_PEER，x/sys 里没有

func wire(cfg netConfig, id, address string, pid int) error {
	ip := net.ParseIP(address).To4()
	gateway := net.ParseIP(cfg.Gateway).To4()
	if ip == nil || gateway == nil {
		return fmt.Errorf("地址 %q 或网关 %q 不是 IPv4", address, cfg.Gateway)
	}
	root, err := netlink.Dial(unix.NETLINK_ROUTE, nil)
	if err != nil {
		return err
	}
	defer root.Close()
	bridge, err := ensureBridge(root, cfg, gateway)
	if err != nil {
		return fmt.Errorf("网桥：%w", err)
	}

	ns, err := os.Open(fmt.Sprintf("/proc/%d/ns/net", pid))
	if err != nil {
		return err
	}
	defer ns.Close()

	// 一对 veth：这头留在虚拟机里挂到网桥上，那头直接建在容器的网络命名空间里叫 eth0
	hostName := fmt.Sprintf("nbxv%d", ip[3])
	peer := netlink.NewAttributeEncoder()
	peer.String(unix.IFLA_IFNAME, "eth0")
	peer.Uint32(unix.IFLA_NET_NS_FD, uint32(ns.Fd()))
	peerAttrs, err := peer.Encode()
	if err != nil {
		return err
	}
	link := netlink.NewAttributeEncoder()
	link.String(unix.IFLA_IFNAME, hostName)
	link.Uint32(unix.IFLA_MASTER, uint32(bridge))
	link.Nested(unix.IFLA_LINKINFO, func(info *netlink.AttributeEncoder) error {
		info.String(unix.IFLA_INFO_KIND, "veth")
		info.Nested(unix.IFLA_INFO_DATA, func(data *netlink.AttributeEncoder) error {
			data.Bytes(vethInfoPeer, append(ifinfo(0, 0, 0), peerAttrs...))
			return nil
		})
		return nil
	})
	if err := request(root, unix.RTM_NEWLINK, netlink.Create|netlink.Excl, ifinfo(0, 0, 0), link); err != nil {
		return fmt.Errorf("建 veth：%w", err)
	}
	host, err := net.InterfaceByName(hostName)
	if err != nil {
		return err
	}
	if err := up(root, host.Index); err != nil {
		return fmt.Errorf("拉起 %s：%w", hostName, err)
	}

	// 容器那头：lo 和 eth0 拉起来，配地址，默认路由指向网桥
	inside, err := netlink.Dial(unix.NETLINK_ROUTE, &netlink.Config{NetNS: int(ns.Fd())})
	if err != nil {
		return fmt.Errorf("进容器的网络命名空间：%w", err)
	}
	defer inside.Close()
	lo, err := linkIndex(inside, "lo")
	if err != nil {
		return err
	}
	eth0, err := linkIndex(inside, "eth0")
	if err != nil {
		return err
	}
	if err := up(inside, lo); err != nil {
		return fmt.Errorf("拉起 lo：%w", err)
	}
	if err := up(inside, eth0); err != nil {
		return fmt.Errorf("拉起 eth0：%w", err)
	}
	if err := addAddress(inside, eth0, ip, cfg.Prefix); err != nil {
		return fmt.Errorf("配地址：%w", err)
	}
	route := netlink.NewAttributeEncoder()
	route.Bytes(unix.RTA_GATEWAY, gateway)
	route.Uint32(unix.RTA_OIF, uint32(eth0))
	rtmsg := []byte{unix.AF_INET, 0, 0, 0, unix.RT_TABLE_MAIN, unix.RTPROT_BOOT, unix.RT_SCOPE_UNIVERSE, unix.RTN_UNICAST, 0, 0, 0, 0}
	if err := request(inside, unix.RTM_NEWROUTE, netlink.Create|netlink.Excl, rtmsg, route); err != nil {
		return fmt.Errorf("默认路由：%w", err)
	}
	return nil
}

// ensureBridge 第一次用到时建网桥、配网关地址、打开转发、加出网时换源地址的规则；之后直接返回它的编号
func ensureBridge(root *netlink.Conn, cfg netConfig, gateway net.IP) (int, error) {
	if found, err := net.InterfaceByName(cfg.Bridge); err == nil {
		return found.Index, nil
	}
	link := netlink.NewAttributeEncoder()
	link.String(unix.IFLA_IFNAME, cfg.Bridge)
	link.Nested(unix.IFLA_LINKINFO, func(info *netlink.AttributeEncoder) error {
		info.String(unix.IFLA_INFO_KIND, "bridge")
		return nil
	})
	if err := request(root, unix.RTM_NEWLINK, netlink.Create|netlink.Excl, ifinfo(0, 0, 0), link); err != nil {
		return 0, fmt.Errorf("建网桥：%w", err)
	}
	bridge, err := net.InterfaceByName(cfg.Bridge)
	if err != nil {
		return 0, err
	}
	if err := addAddress(root, bridge.Index, gateway, cfg.Prefix); err != nil {
		return 0, fmt.Errorf("配网关地址：%w", err)
	}
	if err := up(root, bridge.Index); err != nil {
		return 0, err
	}
	if err := os.WriteFile("/proc/sys/net/ipv4/ip_forward", []byte("1"), 0o644); err != nil {
		return 0, fmt.Errorf("打开转发：%w", err)
	}
	if err := masquerade(cfg, gateway); err != nil {
		return 0, fmt.Errorf("加换源地址的规则：%w", err)
	}
	logf("网桥 %s 建好，网关 %s/%d", cfg.Bridge, gateway, cfg.Prefix)
	return bridge.Index, nil
}

func ifinfo(index int, flags, change uint32) []byte {
	b := make([]byte, unix.SizeofIfInfomsg)
	binary.LittleEndian.PutUint32(b[4:], uint32(index))
	binary.LittleEndian.PutUint32(b[8:], flags)
	binary.LittleEndian.PutUint32(b[12:], change)
	return b
}

func request(c *netlink.Conn, kind uint16, flags netlink.HeaderFlags, header []byte, attrs *netlink.AttributeEncoder) error {
	data := header
	if attrs != nil {
		encoded, err := attrs.Encode()
		if err != nil {
			return err
		}
		data = append(append([]byte{}, header...), encoded...)
	}
	_, err := c.Execute(netlink.Message{
		Header: netlink.Header{Type: netlink.HeaderType(kind), Flags: netlink.Request | netlink.Acknowledge | flags},
		Data:   data,
	})
	return err
}

func up(c *netlink.Conn, index int) error {
	return request(c, unix.RTM_NEWLINK, 0, ifinfo(index, unix.IFF_UP, unix.IFF_UP), nil)
}

func linkIndex(c *netlink.Conn, name string) (int, error) {
	attrs := netlink.NewAttributeEncoder()
	attrs.String(unix.IFLA_IFNAME, name)
	encoded, err := attrs.Encode()
	if err != nil {
		return 0, err
	}
	replies, err := c.Execute(netlink.Message{
		Header: netlink.Header{Type: unix.RTM_GETLINK, Flags: netlink.Request},
		Data:   append(ifinfo(0, 0, 0), encoded...),
	})
	if err != nil {
		return 0, fmt.Errorf("找网卡 %s：%w", name, err)
	}
	if len(replies) != 1 || len(replies[0].Data) < unix.SizeofIfInfomsg {
		return 0, fmt.Errorf("找网卡 %s：回了 %d 条", name, len(replies))
	}
	return int(binary.LittleEndian.Uint32(replies[0].Data[4:8])), nil
}

func addAddress(c *netlink.Conn, index int, ip net.IP, prefix int) error {
	header := make([]byte, unix.SizeofIfAddrmsg)
	header[0] = unix.AF_INET
	header[1] = byte(prefix)
	binary.LittleEndian.PutUint32(header[4:], uint32(index))
	attrs := netlink.NewAttributeEncoder()
	attrs.Bytes(unix.IFA_LOCAL, ip)
	attrs.Bytes(unix.IFA_ADDRESS, ip)
	return request(c, unix.RTM_NEWADDR, netlink.Create|netlink.Excl, header, attrs)
}

// ---- nftables ----

func subnet(cfg netConfig, gateway net.IP) *net.IPNet {
	mask := net.CIDRMask(cfg.Prefix, 32)
	return &net.IPNet{IP: gateway.Mask(mask), Mask: mask}
}

func ifname(key expr.MetaKey, name string, op expr.CmpOp) []expr.Any {
	b := make([]byte, unix.IFNAMSIZ)
	copy(b, name)
	return []expr.Any{&expr.Meta{Key: key, Register: 1}, &expr.Cmp{Op: op, Register: 1, Data: b}}
}

// masquerade：从服务网段出来、不是发回网桥的包，源地址换成虚拟机自己的（外面只认识虚拟机的地址）
func masquerade(cfg netConfig, gateway net.IP) error {
	c, err := nftables.New()
	if err != nil {
		return err
	}
	n := subnet(cfg, gateway)
	table := c.AddTable(&nftables.Table{Family: nftables.TableFamilyIPv4, Name: "nbxnat"})
	chain := c.AddChain(&nftables.Chain{
		Name: "postrouting", Table: table, Type: nftables.ChainTypeNAT,
		Hooknum: nftables.ChainHookPostrouting, Priority: nftables.ChainPriorityNATSource,
	})
	rule := []expr.Any{
		&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 12, Len: 4},
		&expr.Bitwise{SourceRegister: 1, DestRegister: 1, Len: 4, Mask: n.Mask, Xor: make([]byte, 4)},
		&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: n.IP},
	}
	rule = append(rule, ifname(expr.MetaKeyOIFNAME, cfg.Bridge, expr.CmpOpNeq)...)
	rule = append(rule, &expr.Masq{})
	c.AddRule(&nftables.Rule{Table: table, Chain: chain, Exprs: rule})
	return c.Flush()
}

// egress：block 为真时，在转发路径上把"从网桥进来、不是发回网桥"的包挡掉（TCP 回 RST，别的回端口不可达）；
// 为假时把这张表删掉。服务之间、虚拟机自己连服务都不经过这条规则。
func egress(bridge string, block bool) error {
	c, err := nftables.New()
	if err != nil {
		return err
	}
	table := &nftables.Table{Family: nftables.TableFamilyINet, Name: "nbxfw"}
	c.AddTable(table)
	c.DelTable(table)
	if block {
		c.AddTable(table)
		accept := nftables.ChainPolicyAccept
		chain := c.AddChain(&nftables.Chain{
			Name: "forward", Table: table, Type: nftables.ChainTypeFilter,
			Hooknum: nftables.ChainHookForward, Priority: nftables.ChainPriorityFilter, Policy: &accept,
		})
		match := append(ifname(expr.MetaKeyIIFNAME, bridge, expr.CmpOpEq), ifname(expr.MetaKeyOIFNAME, bridge, expr.CmpOpNeq)...)
		tcp := append(append([]expr.Any{}, match...),
			&expr.Meta{Key: expr.MetaKeyL4PROTO, Register: 1},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte{unix.IPPROTO_TCP}},
			&expr.Reject{Type: unix.NFT_REJECT_TCP_RST})
		c.AddRule(&nftables.Rule{Table: table, Chain: chain, Exprs: tcp})
		c.AddRule(&nftables.Rule{Table: table, Chain: chain, Exprs: append(append([]expr.Any{}, match...),
			&expr.Reject{Type: unix.NFT_REJECT_ICMPX_UNREACH, Code: unix.NFT_REJECT_ICMPX_PORT_UNREACH})})
	}
	return c.Flush()
}
