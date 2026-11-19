//go:build linux

package main

import (
	"reflect"
	"testing"
)

func TestParseHostServices(t *testing.T) {
	listen, err := parseHostServices("8317 9000", "10.88.0.1")
	if err != nil || !reflect.DeepEqual(listen, []string{"10.88.0.1:8317", "10.88.0.1:9000"}) {
		t.Fatalf("%v %v", listen, err)
	}
	if listen, err := parseHostServices("", ""); err != nil || listen != nil {
		t.Fatalf("没点名时不听：%v %v", listen, err)
	}
	for _, c := range [][2]string{{"8317", ""}, {"8317", "fd00::1"}, {"0", "10.88.0.1"}, {"70000", "10.88.0.1"}, {"a", "10.88.0.1"}} {
		if _, err := parseHostServices(c[0], c[1]); err == nil {
			t.Errorf("%q %q 应该报错", c[0], c[1])
		}
	}
}
