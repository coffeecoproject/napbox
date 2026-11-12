//go:build linux

package main

import (
	"errors"
	"fmt"
	"io"
	"runtime"

	"golang.org/x/sys/unix"
)

// 宿主机把挂进服务的单个文件整个换掉以后（先写临时文件再改名：编辑器、git、agent 的写文件工具都这么保存），
// 让服务的容器挂上现在这个文件（DESIGN.md 第 8 节）。
//
// 容器里绑定的是文件本身，不是名字。Docker 上换掉以后容器里一直是旧内容；这里更糟：苹果的 virtiofs 不留着被换掉的
// 文件，容器里读它直接报错。所以 napboxd 发现宿主机上的文件换了，就让这里把新的挂上去。
//
// 这条命令在网络小容器里跑，因为这里看得到文件所在的目录（/napbox-src/i，和服务那边是同一份共享）。
// 做法：在这里把新文件做成一个还没挂到任何地方的挂载，进到服务的挂载命名空间，把它垫到原来那个挂载下面，
// 再把原来那个拿掉。容器里任何时刻读这个路径，要么是原来的，要么是新的，中间没有空档。
//
// 一次可以带多个文件，每个四个参数：
//
//	service  服务名
//	source   文件在这个容器里的路径
//	target   文件挂在服务里的哪个路径
//	mode     rw 或 ro
//
// 服务里挂着的已经是现在这个文件时不动挂载，所以 napboxd 也用它来确认"服务里挂着的是哪个"。
// 这时仍然有一个作用：宿主机原地改写了这个文件的话，虚拟机记着的还是旧的大小，容器里按旧大小读，读到截短的内容；
// 重新查名字（lookUpAgain）带回来的是文件现在的大小、修改时间、权限，容器里绑定的是同一个文件，跟着就对了。
// 来源在宿主机上又没了（或者换成了目录、符号链接）没有可挂的：往标准输出写一行 "gone <第几个，从 0 数>"，其余的照常做。
//
// 要 SYS_ADMIN（挂载）、SYS_CHROOT（进别的挂载命名空间）、SYS_PTRACE（打开别的进程的命名空间）、
// DAC_READ_SEARCH（路径上有只让属主进的目录），只有 napboxd 跑这条命令时带上。

// MOVE_MOUNT_BENEATH（Linux 6.5 起），golang.org/x/sys v0.28.0 里还没有
const moveMountBeneath = 0x200

type rebinding struct {
	service, source, target string
	readOnly                bool
	// 来源现在不是一个普通文件
	gone bool
	// 新文件做成的、还没挂到任何地方的挂载
	tree int
	// 新文件是哪一个：服务里挂着的已经是它就不用动
	wanted unix.Stat_t
	// 服务的挂载命名空间
	namespace int
}

func rebindFiles(args []string, out io.Writer) error {
	if len(args) == 0 || len(args)%4 != 0 {
		return fmt.Errorf("rebind 的参数要四个一组：<服务> <来源> <路径> rw|ro")
	}
	// 先在这个容器里把要用的都打开：进了服务的挂载命名空间就看不到这边的路径了
	items := make([]rebinding, len(args)/4)
	namespaces := map[string]int{}
	for i := range items {
		item := &items[i]
		item.service, item.source, item.target = args[4*i], args[4*i+1], args[4*i+2]
		switch args[4*i+3] {
		case "rw":
		case "ro":
			item.readOnly = true
		default:
			return fmt.Errorf("挂载方式只能是 rw 或 ro，不是 %s", args[4*i+3])
		}
		if err := item.open(); err != nil {
			return err
		}
		if item.gone {
			continue
		}
		namespace, known := namespaces[item.service]
		if !known {
			var err error
			if namespace, err = serviceMountNamespace(item.service); err != nil {
				return err
			}
			namespaces[item.service] = namespace
		}
		item.namespace = namespace
	}

	// 进别的挂载命名空间只影响当前线程，而且要求这个线程不和别的线程共用根目录、当前目录。之后不解锁：进程马上就退出
	runtime.LockOSThread()
	if err := unix.Unshare(unix.CLONE_FS); err != nil {
		return fmt.Errorf("unshare(CLONE_FS)：%w", err)
	}
	for i, item := range items {
		if item.gone {
			fmt.Fprintln(out, "gone", i)
			continue
		}
		if err := unix.Setns(item.namespace, unix.CLONE_NEWNS); err != nil {
			return fmt.Errorf("进 %s 的挂载命名空间：%w", item.service, err)
		}
		if err := item.attach(); err != nil {
			return err
		}
	}
	return nil
}

func (item *rebinding) open() error {
	if err := lookUpAgain(item.source); err != nil {
		return err
	}
	file, err := unix.Open(item.source, unix.O_PATH|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if errors.Is(err, unix.ENOENT) {
		item.gone = true
		return nil
	}
	if err != nil {
		return fmt.Errorf("打开 %s：%w", item.source, err)
	}
	defer unix.Close(file)
	if err := unix.Fstat(file, &item.wanted); err != nil {
		return fmt.Errorf("读 %s 的信息：%w", item.source, err)
	}
	if item.wanted.Mode&unix.S_IFMT != unix.S_IFREG {
		item.gone = true
		return nil
	}
	item.tree, err = unix.OpenTree(file, "", unix.OPEN_TREE_CLONE|unix.AT_EMPTY_PATH|unix.O_CLOEXEC)
	if err != nil {
		return fmt.Errorf("把 %s 做成挂载：%w", item.source, err)
	}
	if item.readOnly {
		attr := unix.MountAttr{Attr_set: unix.MOUNT_ATTR_RDONLY}
		if err := unix.MountSetattr(item.tree, "", unix.AT_EMPTY_PATH, &attr); err != nil {
			return fmt.Errorf("把 %s 的挂载设成只读：%w", item.source, err)
		}
	}
	return nil
}

// 已经在服务的挂载命名空间里：路径是服务容器里的路径
func (item *rebinding) attach() error {
	var current unix.Stat_t
	if unix.Stat(item.target, &current) == nil && current.Dev == item.wanted.Dev && current.Ino == item.wanted.Ino {
		return nil
	}
	flags := unix.MOVE_MOUNT_F_EMPTY_PATH | unix.MOVE_MOUNT_T_SYMLINKS | moveMountBeneath
	if err := unix.MoveMount(item.tree, "", unix.AT_FDCWD, item.target, flags); err != nil {
		return fmt.Errorf("把新文件挂到 %s 的 %s：%w", item.service, item.target, err)
	}
	if err := unix.Unmount(item.target, unix.MNT_DETACH); err != nil {
		return fmt.Errorf("拿掉 %s 的 %s 上原来的挂载：%w", item.service, item.target, err)
	}
	return nil
}

// 让虚拟机回宿主机重新查这个名字。虚拟机记着名字对应哪个文件，约 1 秒内不再问宿主机；被换掉的那个文件还挂在容器里，
// 清缓存（vm.drop_caches）清不掉它，这时按名字打开拿到的还是旧文件。文件没换时，问回来的是它现在的大小、修改时间、权限。
// 建硬链接的系统调用查目标名字时一定会回去问（内核对"要新建的名字"不信缓存），而这里注定建不成：
// 名字已经有了是 EEXIST，没有的话因为来源在另一个挂载上是 EXDEV。两种都不会动到宿主机的任何东西。
func lookUpAgain(path string) error {
	err := unix.Link("/napbox-guard", path)
	if errors.Is(err, unix.EEXIST) || errors.Is(err, unix.EXDEV) {
		return nil
	}
	if err == nil {
		return fmt.Errorf("在 %s 建出了一个硬链接，这不应该发生", path)
	}
	return fmt.Errorf("让虚拟机重新查 %s：%w", path, err)
}

// 服务容器的挂载命名空间：从它的 1 号进程拿
func serviceMountNamespace(service string) (int, error) {
	process, err := openServiceInit(service)
	if err != nil {
		return -1, err
	}
	defer unix.Close(process)
	namespace, err := unix.Openat(process, "ns/mnt", unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, fmt.Errorf("打开 %s 的挂载命名空间：%w", service, err)
	}
	return namespace, nil
}
