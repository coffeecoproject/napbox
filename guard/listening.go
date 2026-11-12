package main

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// listeningPorts 解析 /proc/net/tcp 格式：第 2 列是 "十六进制地址:十六进制端口"，第 4 列状态 0A 是 LISTEN
func listeningPorts(r io.Reader) ([]int, error) {
	var ports []int
	s := bufio.NewScanner(r)
	s.Scan() // 表头
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) < 4 {
			return nil, fmt.Errorf("看不懂这一行：%q", s.Text())
		}
		if fields[3] != "0A" {
			continue
		}
		i := strings.LastIndexByte(fields[1], ':')
		port, err := strconv.ParseUint(fields[1][i+1:], 16, 16)
		if i < 0 || err != nil {
			return nil, fmt.Errorf("看不懂本地地址 %q", fields[1])
		}
		ports = append(ports, int(port))
	}
	return ports, s.Err()
}
