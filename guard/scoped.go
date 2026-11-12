package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// 容器里的一个路径，在容器的根文件系统（挂在 root 下）里到底是哪：和内核在容器里解析路径一样，一层一层走，
// 碰到符号链接就跟过去，绝对路径的链接从 root 重新开始，“..”不会走出 root。
// 路径不存在时返回 fs.ErrNotExist。
func resolveInRoot(root, path string) (string, error) {
	pending := strings.Split(path, "/")
	resolved := "" // 相对 root，空的就是 root 自己
	links := 0
	for len(pending) > 0 {
		part := pending[0]
		pending = pending[1:]
		switch part {
		case "", ".":
			continue
		case "..":
			if resolved = filepath.Dir(resolved); resolved == "." {
				resolved = ""
			}
			continue
		}
		next := filepath.Join(resolved, part)
		info, err := os.Lstat(filepath.Join(root, next))
		if err != nil {
			return "", err
		}
		if info.Mode()&fs.ModeSymlink == 0 {
			resolved = next
			continue
		}
		// 和内核的上限一样
		if links++; links > 40 {
			return "", fmt.Errorf("%s：符号链接绕不出来", path)
		}
		target, err := os.Readlink(filepath.Join(root, next))
		if err != nil {
			return "", err
		}
		if strings.HasPrefix(target, "/") {
			resolved = ""
		}
		pending = append(strings.Split(target, "/"), pending...)
	}
	return filepath.Join(root, resolved), nil
}
