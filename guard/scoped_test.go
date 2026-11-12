package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveInRoot(t *testing.T) {
	// macOS 的临时目录本身在符号链接后面，先解开，下面才好比
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(root, "outside")
	rootfs := filepath.Join(root, "rootfs")
	for _, dir := range []string{"outside/secret", "rootfs/var/spool/mail", "rootfs/data/media", "rootfs/etc"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	links := map[string]string{
		"var/mail":     "spool/mail",         // 相对链接
		"abs":          "/data/media",        // 绝对链接：从容器的根开始，不是虚拟机的根
		"escape":       "../../outside",      // 想走出去：停在根
		"abs-escape":   outside,              // 绝对路径指向根外面的同名位置：在根里找，找不到
		"chain":        "abs/../../var/mail", // 链接套链接
		"loop":         "loop",
		"etc/dangling": "/nowhere",
	}
	for name, target := range links {
		if err := os.Symlink(target, filepath.Join(rootfs, name)); err != nil {
			t.Fatal(err)
		}
	}

	found := map[string]string{
		"/data/media":         "data/media",
		"data/media/":         "data/media",
		"/":                   "",
		"/var/mail":           "var/spool/mail",
		"/abs":                "data/media",
		"/chain":              "var/spool/mail",
		"/data/../../../etc":  "etc",
		"/escape":             "outside-not-here",
		"/var/./spool//mail/": "var/spool/mail",
	}
	for path, want := range found {
		got, err := resolveInRoot(rootfs, path)
		if want == "outside-not-here" {
			// ../../outside 在根里解析成 /outside，根里没有这个目录
			if !errors.Is(err, fs.ErrNotExist) {
				t.Errorf("%s：应该找不到，得到 %q %v", path, got, err)
			}
			continue
		}
		if err != nil || got != filepath.Join(rootfs, want) {
			t.Errorf("%s：要 %q，得到 %q %v", path, filepath.Join(rootfs, want), got, err)
		}
	}
	for _, path := range []string{"/nope", "/data/nope/x", "/escape/../data", "/abs-escape", "/abs-escape/secret", "/etc/dangling"} {
		if got, err := resolveInRoot(rootfs, path); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("%s：应该找不到，得到 %q %v", path, got, err)
		}
	}
	if got, err := resolveInRoot(rootfs, "/loop"); err == nil || errors.Is(err, fs.ErrNotExist) {
		t.Errorf("/loop：应该报绕不出来，得到 %q %v", got, err)
	}
}
