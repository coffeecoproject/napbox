//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync/atomic"

	"golang.org/x/sys/unix"
)

// 文件变化通知的虚拟机这一头：宿主机改了挂载目录里的文件，虚拟机内核不知道，容器里的
// inotify 收不到。napboxd 把变化的路径从 vsock 发过来，这里对着同一份挂载做一次属性操作，让内核发出事件。
//
// 用“权限不变的 chmod”，不用 touch：chmod 只动 ctime，文件的修改时间不变，宿主机上的构建工具和 git 看到的还是
// 真实的时间；touch 或者写回修改时间，碰巧和宿主机的下一次保存同时发生时会把时间改乱。它发出的是 IN_ATTRIB。
//
// 虚拟化框架不让改共享根目录的属性（报 EPERM），所以根目录下有文件被删时（item.Mode 为空）在里面建一个临时目录
// 再删掉：内核发出 IN_CREATE 和 IN_DELETE，监听的程序会重新读这个目录，发现文件没了。
const notifyPort = 5301

type notifyItem struct {
	Path string  `json:"path"`
	Mode *uint32 `json:"mode,omitempty"`
}

type notifyResult struct {
	Failed int    `json:"failed"`
	First  string `json:"first,omitempty"`
}

var notifySignals atomic.Uint64

func serveNotify() error {
	return serveVsock(notifyPort, func(host *os.File) {
		reader := bufio.NewReaderSize(host, 1<<20)
		encoder := json.NewEncoder(host)
		for {
			line, err := reader.ReadBytes('\n')
			if err != nil {
				return
			}
			var items []notifyItem
			if err := json.Unmarshal(line, &items); err != nil {
				fmt.Fprintln(os.Stderr, "文件变化通知读不懂：", err)
				return
			}
			if err := encoder.Encode(applyNotifications(items)); err != nil {
				return
			}
		}
	})
}

func applyNotifications(items []notifyItem) notifyResult {
	var result notifyResult
	for _, item := range items {
		// 文件在这期间又被删了不算失败：宿主机马上会为这次删除再发一条
		if err := applyNotification(item); err != nil && !errors.Is(err, fs.ErrNotExist) {
			result.Failed++
			if result.First == "" {
				result.First = fmt.Sprintf("%s：%v", item.Path, err)
			}
		}
	}
	return result
}

func applyNotification(item notifyItem) error {
	if item.Mode != nil {
		return unix.Chmod(item.Path, *item.Mode)
	}
	name := filepath.Join(item.Path, fmt.Sprintf(".napbox-notify-%d", notifySignals.Add(1)))
	if err := unix.Mkdir(name, 0o755); err != nil {
		return err
	}
	return unix.Rmdir(name)
}
