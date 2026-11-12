//go:build linux

package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
	"github.com/mdlayher/netlink"
	"golang.org/x/sys/unix"
)

// 每个服务自己的网络（DESIGN.md 第 6 节）：虚拟机里一个网桥，每个服务的容器用一对 veth 接上来，各有各的地址。
//
//	服务 A（eth0 10.88.0.2）─┐
//	服务 B（eth0 10.88.0.3）─┼─ 网桥 nbx0（10.88.0.1）── 虚拟机的网卡 ── 宿主机、外网
//	服务 C（eth0 10.88.0.4）─┘
//
// 服务之间直接在网桥上互通。服务出网时虚拟机替它转发，源地址换成虚拟机自己的（外面只认识虚拟机的地址）；
// 出网规则加在转发这条路上（egress.go）。宿主机连服务：网络小容器在虚拟机的网络里，直接连服务的地址（relay.go）。
//
// 这些由垫在 runc 前面那一层在建容器时做（runtime.go），在虚拟机自己的网络命名空间里、以 root 运行。
const (
	bridgeName = "nbx0"
	// 换源地址的规则单独一张表：出网规则换的时候整张表删掉重建（egress.go），不能连它一起删了
	natTable = "napbox-nat"
	// 服务可能同时在建，网桥只能建一次
	networkLock = "/run/napbox-net.lock"
	// linux/veth.h 的 VETH_INFO_PEER，golang.org/x/sys 里没有
	vethInfoPeer = 1
)

// 网桥的硬件地址定死。不定的话它跟着接上来的网卡里最小的那个走，停掉一个服务就可能变，
// 别的服务记着的网关硬件地址跟着失效，要等它们重新问到才通。
var bridgeAddress = net.HardwareAddr{0x02, 0x6e, 0x62, 0x78, 0x00, 0x01}

// 把刚建好的容器（1 号进程 pid，服务的程序还没开始跑）接到网桥上，配好地址和默认路由
func connectService(network serviceNetwork, pid int) error {
	lock, err := os.OpenFile(networkLock, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		return fmt.Errorf("锁 %s：%w", networkLock, err)
	}

	root, err := netlink.Dial(unix.NETLINK_ROUTE, nil)
	if err != nil {
		return err
	}
	defer root.Close()
	bridge, err := ensureBridge(root, network)
	if err != nil {
		return err
	}
	namespace, err := os.Open(fmt.Sprintf("/proc/%d/ns/net", pid))
	if err != nil {
		return err
	}
	defer namespace.Close()

	// 一对 veth：这头留在虚拟机里挂到网桥上，那头直接建在容器的网络命名空间里，叫 eth0。
	// 这头的名字按地址取。一台虚拟机里每个服务只建一次（单个服务不单独重启，要重启是整个环境换一台虚拟机），
	// 所以这个名字不会已经有了；真有了下面建的时候直接报错
	hostName := fmt.Sprintf("nbx%02x%02x%02x%02x", network.address[0], network.address[1], network.address[2], network.address[3])
	peer := netlink.NewAttributeEncoder()
	peer.String(unix.IFLA_IFNAME, "eth0")
	peer.Uint32(unix.IFLA_NET_NS_FD, uint32(namespace.Fd()))
	peerAttributes, err := peer.Encode()
	if err != nil {
		return err
	}
	link := netlink.NewAttributeEncoder()
	link.String(unix.IFLA_IFNAME, hostName)
	link.Uint32(unix.IFLA_MASTER, uint32(bridge))
	link.Nested(unix.IFLA_LINKINFO, func(info *netlink.AttributeEncoder) error {
		info.String(unix.IFLA_INFO_KIND, "veth")
		info.Nested(unix.IFLA_INFO_DATA, func(data *netlink.AttributeEncoder) error {
			data.Bytes(vethInfoPeer, append(ifinfo(0, 0, 0), peerAttributes...))
			return nil
		})
		return nil
	})
	if err := request(root, unix.RTM_NEWLINK, netlink.Create|netlink.Excl, ifinfo(0, 0, 0), link); err != nil {
		return fmt.Errorf("建 veth %s：%w", hostName, err)
	}
	host, err := net.InterfaceByName(hostName)
	if err != nil {
		return err
	}
	if err := setUp(root, host.Index); err != nil {
		return fmt.Errorf("拉起 %s：%w", hostName, err)
	}

	// 容器那头：lo 和 eth0 拉起来，配地址，默认路由指向网桥
	inside, err := netlink.Dial(unix.NETLINK_ROUTE, &netlink.Config{NetNS: int(namespace.Fd())})
	if err != nil {
		return fmt.Errorf("进容器的网络命名空间：%w", err)
	}
	defer inside.Close()
	prefix, _ := network.mask.Size()
	for _, name := range []string{"lo", "eth0"} {
		index, err := linkIndex(inside, name)
		if err != nil {
			return err
		}
		if err := setUp(inside, index); err != nil {
			return fmt.Errorf("拉起容器里的 %s：%w", name, err)
		}
		if name != "eth0" {
			continue
		}
		if err := addAddress(inside, index, network.address, prefix); err != nil {
			return fmt.Errorf("配地址 %s：%w", network.address, err)
		}
		route := netlink.NewAttributeEncoder()
		route.Bytes(unix.RTA_GATEWAY, network.gateway)
		route.Uint32(unix.RTA_OIF, uint32(index))
		// rtmsg：地址族、目的和来源的掩码长度（0 就是默认路由）、TOS、路由表、谁加的、范围、类型、标志
		header := []byte{unix.AF_INET, 0, 0, 0, unix.RT_TABLE_MAIN, unix.RTPROT_BOOT, unix.RT_SCOPE_UNIVERSE, unix.RTN_UNICAST, 0, 0, 0, 0}
		if err := request(inside, unix.RTM_NEWROUTE, netlink.Create|netlink.Excl, header, route); err != nil {
			return fmt.Errorf("默认路由：%w", err)
		}
	}
	return nil
}

// 网桥在就直接用；不在就先打开转发、加上换源地址的规则，再建网桥。网桥最后建、建到一半失败就删掉，
// 所以它在就说明这几样都好了。返回网桥的编号
func ensureBridge(root *netlink.Conn, network serviceNetwork) (int, error) {
	if found, err := net.InterfaceByName(bridgeName); err == nil {
		return found.Index, nil
	}
	if err := os.WriteFile("/proc/sys/net/ipv4/ip_forward", []byte("1"), 0o644); err != nil {
		return 0, fmt.Errorf("打开转发：%w", err)
	}
	if err := masquerade(network); err != nil {
		return 0, fmt.Errorf("加换源地址的规则：%w", err)
	}
	link := netlink.NewAttributeEncoder()
	link.String(unix.IFLA_IFNAME, bridgeName)
	link.Bytes(unix.IFLA_ADDRESS, bridgeAddress)
	link.Nested(unix.IFLA_LINKINFO, func(info *netlink.AttributeEncoder) error {
		info.String(unix.IFLA_INFO_KIND, "bridge")
		return nil
	})
	if err := request(root, unix.RTM_NEWLINK, netlink.Create|netlink.Excl, ifinfo(0, 0, 0), link); err != nil {
		return 0, fmt.Errorf("建网桥：%w", err)
	}
	bridge, err := net.InterfaceByName(bridgeName)
	if err != nil {
		return 0, err
	}
	prefix, _ := network.mask.Size()
	err = addAddress(root, bridge.Index, network.gateway, prefix)
	if err == nil {
		err = setUp(root, bridge.Index)
	}
	if err != nil {
		_ = request(root, unix.RTM_DELLINK, 0, ifinfo(bridge.Index, 0, 0), nil)
		return 0, fmt.Errorf("配网桥：%w", err)
	}
	return bridge.Index, nil
}

// 从服务网段出来、不是发回网桥的包，源地址换成虚拟机自己的
func masquerade(network serviceNetwork) error {
	c, err := nftables.New()
	if err != nil {
		return err
	}
	table := &nftables.Table{Family: nftables.TableFamilyIPv4, Name: natTable}
	c.AddTable(table)
	c.DelTable(table)
	c.AddTable(table)
	chain := c.AddChain(&nftables.Chain{
		Name: "postrouting", Table: table, Type: nftables.ChainTypeNAT,
		Hooknum: nftables.ChainHookPostrouting, Priority: nftables.ChainPriorityNATSource,
	})
	// IPv4 头第 12 字节起 4 字节是源地址
	rule := []expr.Any{
		&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 12, Len: 4},
		&expr.Bitwise{SourceRegister: 1, DestRegister: 1, Len: 4, Mask: network.mask, Xor: make([]byte, 4)},
		eq(network.gateway.Mask(network.mask)),
	}
	rule = append(rule, ifname(expr.MetaKeyOIFNAME, bridgeName, expr.CmpOpNeq)...)
	c.AddRule(&nftables.Rule{Table: table, Chain: chain, Exprs: append(rule, &expr.Masq{})})
	return c.Flush()
}

// ---- rtnetlink：虚拟机里没有 ip 命令，直接和内核说 ----

// ifinfomsg：地址族、类型、网卡编号、标志、要改哪些标志
func ifinfo(index int, flags, change uint32) []byte {
	b := make([]byte, unix.SizeofIfInfomsg)
	binary.LittleEndian.PutUint32(b[4:], uint32(index))
	binary.LittleEndian.PutUint32(b[8:], flags)
	binary.LittleEndian.PutUint32(b[12:], change)
	return b
}

func request(c *netlink.Conn, kind uint16, flags netlink.HeaderFlags, header []byte, attributes *netlink.AttributeEncoder) error {
	data := header
	if attributes != nil {
		encoded, err := attributes.Encode()
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

func setUp(c *netlink.Conn, index int) error {
	return request(c, unix.RTM_NEWLINK, 0, ifinfo(index, unix.IFF_UP, unix.IFF_UP), nil)
}

func linkIndex(c *netlink.Conn, name string) (int, error) {
	attributes := netlink.NewAttributeEncoder()
	attributes.String(unix.IFLA_IFNAME, name)
	encoded, err := attributes.Encode()
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
	// ifaddrmsg：地址族、掩码长度、标志、范围、网卡编号
	header := make([]byte, unix.SizeofIfAddrmsg)
	header[0] = unix.AF_INET
	header[1] = byte(prefix)
	binary.LittleEndian.PutUint32(header[4:], uint32(index))
	attributes := netlink.NewAttributeEncoder()
	attributes.Bytes(unix.IFA_LOCAL, ip)
	attributes.Bytes(unix.IFA_ADDRESS, ip)
	return request(c, unix.RTM_NEWADDR, netlink.Create|netlink.Excl, header, attributes)
}
