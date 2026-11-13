//go:build linux

package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// 新的命名卷带上镜像里那个目录的内容，规则照 Docker 建容器时的做法（moby 的
// populateVolume 和 containerd 的 fs.CopyDir）：镜像里有这个目录、卷是空的，就把目录里的东西连同属主、权限、
// 扩展属性、时间复制进卷，卷的根目录也改成镜像里那个目录的属主和权限。镜像里没有这个目录，或者卷里已经有东西，就不动。
//
// 复制期间卷的根目录里有一个标记（populatingMark），复制完才删。虚拟机中途没了、复制出错时它留着：下次看到它，
// 卷里的是上次复制到一半的内容，清掉重来，不当成“卷里已经有东西”。返回成功时标记已经删掉、内容已经落盘。
//
// 在这里做是因为这里同时看得到两边：服务的根文件系统和卷都挂在这个容器里（napboxd 里的 GuardContainer）。
// 服务这时还没启动。
//
//	rootfs  服务的根文件系统在这个容器里的路径
//	target  卷挂在服务里的哪个路径
//	volume  卷在这个容器里的路径
func populateVolume(rootfs, target, volume string) error {
	source, err := resolveInRoot(rootfs, target)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var info unix.Stat_t
	if err := unix.Lstat(source, &info); err != nil {
		return &fs.PathError{Op: "lstat", Path: source, Err: err}
	}
	if info.Mode&unix.S_IFMT != unix.S_IFDIR {
		return fmt.Errorf("镜像里的 %s 不是目录，挂不了卷", target)
	}
	existing, err := os.ReadDir(volume)
	if err != nil {
		return err
	}
	mark := filepath.Join(volume, populatingMark)
	interrupted := false
	for _, entry := range existing {
		if entry.Name() == populatingMark {
			interrupted = true
		}
	}
	switch {
	case interrupted:
		for _, entry := range existing {
			if entry.Name() == populatingMark {
				continue
			}
			if err := os.RemoveAll(filepath.Join(volume, entry.Name())); err != nil {
				return err
			}
		}
	case len(existing) != 0:
		return nil
	default:
		// 标记先落盘，再开始复制：磁盘上只要有复制进来的内容，就一定有标记
		if err := os.WriteFile(mark, nil, 0o600); err != nil {
			return err
		}
		if err := syncFilesystem(volume); err != nil {
			return err
		}
	}
	copier := treeCopier{links: map[inode]string{}}
	if err := copier.copyChildren(source, volume); err != nil {
		return err
	}
	if err := copyAttributes(source, volume, &info); err != nil {
		return err
	}
	if err := os.Remove(mark); err != nil {
		return err
	}
	// 删标记动了卷根目录的修改时间，再照镜像里的设一次
	times := []unix.Timespec{info.Atim, info.Mtim}
	if err := unix.UtimesNanoAt(unix.AT_FDCWD, volume, times, 0); err != nil {
		return &fs.PathError{Op: "utimensat", Path: volume, Err: err}
	}
	return syncFilesystem(volume)
}

// 卷的根目录里表示“正在复制、还没复制完”的文件
const populatingMark = ".napbox-populating"

// 把 path 所在的文件系统刷到磁盘
func syncFilesystem(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	if err := unix.Syncfs(int(directory.Fd())); err != nil {
		return &fs.PathError{Op: "syncfs", Path: path, Err: err}
	}
	return nil
}

type inode struct{ device, number uint64 }

type treeCopier struct {
	// 有多个名字的文件第一次复制到了哪：后面的名字做成硬链接，不再复制一份
	links map[inode]string
}

func (c *treeCopier) copyChildren(source, destination string) error {
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := c.copy(filepath.Join(source, entry.Name()), filepath.Join(destination, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func (c *treeCopier) copy(source, destination string) error {
	var info unix.Stat_t
	if err := unix.Lstat(source, &info); err != nil {
		return &fs.PathError{Op: "lstat", Path: source, Err: err}
	}
	switch info.Mode & unix.S_IFMT {
	case unix.S_IFDIR:
		// 先建成只有自己能进的，里面的东西放好再改成原来的权限
		if err := unix.Mkdir(destination, 0o700); err != nil {
			return &fs.PathError{Op: "mkdir", Path: destination, Err: err}
		}
		if err := c.copyChildren(source, destination); err != nil {
			return err
		}
	case unix.S_IFREG:
		if info.Nlink > 1 {
			key := inode{uint64(info.Dev), info.Ino}
			if first, ok := c.links[key]; ok {
				return os.Link(first, destination)
			}
			c.links[key] = destination
		}
		if err := copyContent(source, destination); err != nil {
			return err
		}
	case unix.S_IFLNK:
		target, err := os.Readlink(source)
		if err != nil {
			return err
		}
		if err := os.Symlink(target, destination); err != nil {
			return err
		}
	default:
		// 设备、管道、套接字
		if err := unix.Mknod(destination, info.Mode, int(info.Rdev)); err != nil {
			return &fs.PathError{Op: "mknod", Path: destination, Err: err}
		}
	}
	return copyAttributes(source, destination, &info)
}

func copyContent(source, destination string) error {
	from, err := os.Open(source)
	if err != nil {
		return err
	}
	defer from.Close()
	to, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(to, from); err != nil {
		to.Close()
		return fmt.Errorf("复制 %s：%w", source, err)
	}
	return to.Close()
}

// 属主、权限、扩展属性、时间。顺序有讲究：改属主会清掉 setuid 位和文件的 capabilities，所以先改属主；
// 时间放最后，前面几步都会动它。
func copyAttributes(source, destination string, info *unix.Stat_t) error {
	fail := func(op string, err error) error { return &fs.PathError{Op: op, Path: destination, Err: err} }
	if err := unix.Lchown(destination, int(info.Uid), int(info.Gid)); err != nil {
		return fail("lchown", err)
	}
	// 符号链接没有自己的权限
	if info.Mode&unix.S_IFMT != unix.S_IFLNK {
		if err := unix.Chmod(destination, info.Mode&0o7777); err != nil {
			return fail("chmod", err)
		}
	}
	if err := copyExtendedAttributes(source, destination); err != nil {
		return err
	}
	times := []unix.Timespec{info.Atim, info.Mtim}
	if err := unix.UtimesNanoAt(unix.AT_FDCWD, destination, times, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return fail("utimensat", err)
	}
	return nil
}

func copyExtendedAttributes(source, destination string) error {
	size, err := unix.Llistxattr(source, nil)
	if err != nil {
		return &fs.PathError{Op: "llistxattr", Path: source, Err: err}
	}
	if size == 0 {
		return nil
	}
	names := make([]byte, size)
	if size, err = unix.Llistxattr(source, names); err != nil {
		return &fs.PathError{Op: "llistxattr", Path: source, Err: err}
	}
	for _, raw := range splitNames(names[:size]) {
		name := string(raw)
		length, err := unix.Lgetxattr(source, name, nil)
		if err != nil {
			return &fs.PathError{Op: "lgetxattr " + name, Path: source, Err: err}
		}
		value := make([]byte, length)
		if length, err = unix.Lgetxattr(source, name, value); err != nil {
			return &fs.PathError{Op: "lgetxattr " + name, Path: source, Err: err}
		}
		if err := unix.Lsetxattr(destination, name, value[:length], 0); err != nil {
			return &fs.PathError{Op: "lsetxattr " + name, Path: destination, Err: err}
		}
	}
	return nil
}

// llistxattr 给的是一串用 0 结尾的名字
func splitNames(list []byte) [][]byte {
	var names [][]byte
	for start, i := 0, 0; i < len(list); i++ {
		if list[i] == 0 {
			if i > start {
				names = append(names, list[start:i])
			}
			start = i + 1
		}
	}
	return names
}
