//go:build linux

package main

import (
	"fmt"
	"net"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
	"golang.org/x/sys/unix"
)

// 出网规则，只管服务自己发起的连接。挡哪些网段、放行哪个 DNS 由 napboxd 传进来，这里只负责加。
// 服务各有自己的网络，出网都要经过虚拟机转发（network.go），规则就加在转发这条路上：
//   - 不是从服务那边来的包（外面回给服务的包）一律放行；
//   - 服务发给别的服务的一律放行。它们在同一个网桥上，包不出虚拟机，但内核照样让它过一遍转发的规则；
//   - open <DNS 服务器> <网段或地址...>：放行到 DNS 服务器的 53 端口，挡住列出的网段和地址，其余（外网）放行；
//   - none：其余全部挡住，DNS 也挡。已经建立的出网连接，服务之后发的包也会被挡，切过来就断。
//
// 宿主机经端口转发连进来的连接不走转发这条路（网络小容器在虚拟机的网络里，直接连服务的地址），不受影响。
// 挡的方式：TCP 回 RST（新连接立刻被拒、已有连接立刻断），别的回 ICMP 端口不可达。
const tableName = "napbox"

// args：open 后面是 DNS 服务器和要挡的网段或地址，none 后面没有
func applyEgress(mode string, args []string) error {
	var dns *net.IPNet
	var blocked []*net.IPNet
	switch {
	case mode == "open" && len(args) >= 1:
		var err error
		if dns, err = target(args[0]); err != nil || len(dns.IP) != net.IPv4len {
			return fmt.Errorf("DNS 服务器 %q 不是 IPv4 地址", args[0])
		}
		for _, a := range args[1:] {
			n, err := target(a)
			if err != nil {
				return err
			}
			blocked = append(blocked, n)
		}
	case mode == "none" && len(args) == 0:
	default:
		return fmt.Errorf("用法：egress open <DNS 服务器> [网段或地址...] | egress none")
	}
	c, err := nftables.New()
	if err != nil {
		return err
	}
	// 先确保表存在再删掉重建：整批是一个事务，规则要么全换成新的，要么保持原样
	table := &nftables.Table{Family: nftables.TableFamilyINet, Name: tableName}
	c.AddTable(table)
	c.DelTable(table)
	c.AddTable(table)
	accept := nftables.ChainPolicyAccept
	chain := c.AddChain(&nftables.Chain{
		Name: "forward", Table: table, Type: nftables.ChainTypeFilter,
		Hooknum: nftables.ChainHookForward, Priority: nftables.ChainPriorityFilter, Policy: &accept,
	})
	add := func(exprs ...expr.Any) { c.AddRule(&nftables.Rule{Table: table, Chain: chain, Exprs: exprs}) }
	acceptVerdict := &expr.Verdict{Kind: expr.VerdictAccept}

	add(append(ifname(expr.MetaKeyIIFNAME, bridgeName, expr.CmpOpNeq), acceptVerdict)...)
	add(append(ifname(expr.MetaKeyOIFNAME, bridgeName, expr.CmpOpEq), acceptVerdict)...)

	if mode == "open" {
		for _, proto := range []byte{unix.IPPROTO_UDP, unix.IPPROTO_TCP} {
			rule := append(nfproto(unix.NFPROTO_IPV4), daddr(dns)...)
			rule = append(rule, l4proto(proto)...)
			add(append(rule, &expr.Payload{DestRegister: 1, Base: expr.PayloadBaseTransportHeader, Offset: 2, Len: 2}, eq([]byte{0, 53}), acceptVerdict)...)
		}
		for _, n := range blocked {
			family := byte(unix.NFPROTO_IPV6)
			if len(n.IP) == net.IPv4len {
				family = unix.NFPROTO_IPV4
			}
			reject(add, append(nfproto(family), daddr(n)...))
		}
	} else {
		reject(add, nil)
	}
	if err := c.Flush(); err != nil {
		return fmt.Errorf("加出网规则失败：%w", err)
	}
	return nil
}

// reject 对匹配 match 的包：TCP 回 RST，其余回 ICMP 端口不可达
func reject(add func(...expr.Any), match []expr.Any) {
	tcp := append(append([]expr.Any{}, match...), l4proto(unix.IPPROTO_TCP)...)
	add(append(tcp, &expr.Reject{Type: unix.NFT_REJECT_TCP_RST})...)
	add(append(append([]expr.Any{}, match...), &expr.Reject{Type: unix.NFT_REJECT_ICMPX_UNREACH, Code: unix.NFT_REJECT_ICMPX_PORT_UNREACH})...)
}

func eq(data []byte) *expr.Cmp { return &expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: data} }

// ifname 匹配包进来（IIFNAME）或出去（OIFNAME）的网卡叫不叫这个名字
func ifname(key expr.MetaKey, name string, op expr.CmpOp) []expr.Any {
	b := make([]byte, unix.IFNAMSIZ)
	copy(b, name)
	return []expr.Any{&expr.Meta{Key: key, Register: 1}, &expr.Cmp{Op: op, Register: 1, Data: b}}
}

func nfproto(p byte) []expr.Any {
	return []expr.Any{&expr.Meta{Key: expr.MetaKeyNFPROTO, Register: 1}, eq([]byte{p})}
}

func l4proto(p byte) []expr.Any {
	return []expr.Any{&expr.Meta{Key: expr.MetaKeyL4PROTO, Register: 1}, eq([]byte{p})}
}

// daddr 匹配目的地址在网段 n 里：IPv4 头第 16 字节起 4 字节，IPv6 头第 24 字节起 16 字节
func daddr(n *net.IPNet) []expr.Any {
	ip, offset := n.IP.To4(), uint32(16)
	if ip == nil {
		ip, offset = n.IP.To16(), 24
	}
	size := uint32(len(ip))
	return []expr.Any{
		&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: offset, Len: size},
		&expr.Bitwise{SourceRegister: 1, DestRegister: 1, Len: size, Mask: n.Mask, Xor: make([]byte, size)},
		eq(ip.Mask(n.Mask)),
	}
}

// target 解析网段（10.0.0.0/8）或单个地址（198.18.0.1，当成 /32 或 /128）。IPv4 的 IP 是 4 字节
func target(s string) (*net.IPNet, error) {
	if _, n, err := net.ParseCIDR(s); err == nil {
		return n, nil
	}
	ip := net.ParseIP(s)
	if ip == nil {
		return nil, fmt.Errorf("%q 不是网段或 IP 地址", s)
	}
	bits := 128
	if ip.To4() != nil {
		ip, bits = ip.To4(), 32
	}
	return &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)}, nil
}
