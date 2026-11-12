package main

import (
	"reflect"
	"strings"
	"testing"
)

// 取自虚拟机里 postgres（5432，IPv4 和 IPv6 各一）和一条已建立连接的真实格式
func TestListeningPorts(t *testing.T) {
	tcp := `  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000    70        0 2345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2346 1 0000000000000000 100 0 0 10 0
   2: 8040A8C0:1538 0140A8C0:D2F4 01 00000000:00000000 00:00000000 00000000    70        0 2400 1 0000000000000000 20 4 30 10 -1
`
	tcp6 := `  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:1538 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000    70        0 2347 1 0000000000000000 100 0 0 10 0
`
	got, err := listeningPorts(strings.NewReader(tcp))
	if err != nil || !reflect.DeepEqual(got, []int{5432, 8080}) {
		t.Fatalf("tcp：%v %v", got, err)
	}
	got, err = listeningPorts(strings.NewReader(tcp6))
	if err != nil || !reflect.DeepEqual(got, []int{5432}) {
		t.Fatalf("tcp6：%v %v", got, err)
	}
	if _, err := listeningPorts(strings.NewReader("header\n 0: bad\n")); err == nil {
		t.Fatal("坏行应该报错")
	}
}
