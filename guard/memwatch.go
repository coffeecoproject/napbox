//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

// 看着各服务的内存：服务卡在内存上时，找出该结束的进程报给 napboxd，由它结束（memwatch_logic.go 定怎么判断）。
//
// 虚拟机没有交换空间。服务的内存到了上限，或者整个虚拟机的内存用完时，内核一直把程序的代码页挤出去再读回来，
// 每次都算回收成功，不按内存不足结束进程，服务能卡几十分钟（DESIGN.md 第 2 节「服务卡在内存上限」）。
// 内存压力统计（PSI，napboxd 给内核加了 psi=1）看得出来：卡住时服务的 full avg10 几秒内到 30 以上，平时是 0。
//
// 这里结束不了：别的容器的进程不在这个容器的进程命名空间里，发不了信号。napboxd 经 vminitd 按虚拟机里的进程号结束它。

// 虚拟机的 cgroup 只读挂在这（napboxd 里的 GuardContainer）：这个容器自己的 /sys/fs/cgroup 只看得到它自己
const vmCgroup = "/napbox-vmcgroup"

// napboxd 连这个端口收卡住的报告
const memoryPort = 5302

var memorySubscribers = struct {
	sync.Mutex
	encoders map[*json.Encoder]struct{}
}{encoders: map[*json.Encoder]struct{}{}}

// 看不了（读不到虚拟机的 cgroup、内核没开内存压力统计）就报错退出：不能留一个看起来正常、卡住了却没人管的环境
func serveMemory() error {
	pod, err := podCgroup()
	if err != nil {
		return fmt.Errorf("看不了各服务的内存：%w", err)
	}
	if _, err := os.ReadFile(filepath.Join(pod, "memory.pressure")); err != nil {
		return fmt.Errorf("读不了内存压力（内核的 psi 没打开？）：%w", err)
	}
	if _, err := os.Stat(vmProc); err != nil {
		return fmt.Errorf("看不了虚拟机的进程：%w", err)
	}
	failed := make(chan error, 2)
	go func() { failed <- watchMemory(pod) }()
	go func() { failed <- serveVsock(memoryPort, subscribeMemory) }()
	return <-failed
}

// napboxd 连上来收报告
func subscribeMemory(host *os.File) {
	encoder := json.NewEncoder(host)
	memorySubscribers.Lock()
	memorySubscribers.encoders[encoder] = struct{}{}
	memorySubscribers.Unlock()
	// napboxd 不往这条连接写东西：读到结束就是它断开了
	buffer := make([]byte, 64)
	for {
		if _, err := host.Read(buffer); err != nil {
			break
		}
	}
	memorySubscribers.Lock()
	delete(memorySubscribers.encoders, encoder)
	memorySubscribers.Unlock()
}

func publishMemory(report memoryReport) {
	memorySubscribers.Lock()
	defer memorySubscribers.Unlock()
	for encoder := range memorySubscribers.encoders {
		encoder.Encode(report)
	}
}

func watchMemory(pod string) error {
	watcher := newMemoryWatcher()
	for range time.Tick(time.Second) {
		services, err := readServiceMemory(pod)
		if err != nil {
			return fmt.Errorf("读各服务的内存失败：%w", err)
		}
		if report, ok := watcher.observe(time.Now(), services, largestProcesses); ok {
			publishMemory(report)
		}
	}
	return nil
}

// 虚拟机里只有一个 pod：/container/pod/<pod>（同一层还有 cgroup 自己的那些文件）。这个容器自己就在里面，它起来时已经有了
func podCgroup() (string, error) {
	entries, err := os.ReadDir(vmCgroup + "/container/pod")
	if err != nil {
		return "", err
	}
	var pods []string
	for _, entry := range entries {
		if entry.IsDir() {
			pods = append(pods, entry.Name())
		}
	}
	if len(pods) != 1 {
		return "", fmt.Errorf("%s/container/pod 下应该正好有一个 pod，有 %d 个", vmCgroup, len(pods))
	}
	return filepath.Join(vmCgroup, "container/pod", pods[0]), nil
}

// 服务刚好停了（它的 cgroup 没了）的跳过；别的读不到算出错
func readServiceMemory(pod string) ([]serviceMemory, error) {
	entries, err := os.ReadDir(pod)
	if err != nil {
		return nil, err
	}
	var services []serviceMemory
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || name == guardContainer || name == runtimeContainer {
			continue
		}
		service, err := readCgroupMemory(name, filepath.Join(pod, name))
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		services = append(services, service)
	}
	return services, nil
}

func readCgroupMemory(name, dir string) (serviceMemory, error) {
	read := func(file string) (string, error) {
		content, err := os.ReadFile(filepath.Join(dir, file))
		return string(content), err
	}
	pressure, err := read("memory.pressure")
	if err != nil {
		return serviceMemory{}, err
	}
	current, err := read("memory.current")
	if err != nil {
		return serviceMemory{}, err
	}
	max, err := read("memory.max")
	if err != nil {
		return serviceMemory{}, err
	}
	service := serviceMemory{name: name, stalled: fullAvg10(pressure)}
	if service.current, err = memoryValue(current); err != nil {
		return serviceMemory{}, err
	}
	if service.limit, err = memoryValue(max); err != nil {
		return serviceMemory{}, err
	}
	return service, nil
}

// 每个服务里占内存最多的进程：从虚拟机的 /proc 认（这个容器自己的 /proc 看不到别的服务的进程）。
// 进程号是虚拟机里的号，napboxd 经 vminitd 结束它时用的就是这个号。
func largestProcesses() map[string]processMemory {
	entries, err := os.ReadDir(vmProc)
	if err != nil {
		return nil
	}
	largest := map[string]processMemory{}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		cgroup, err := os.ReadFile(filepath.Join(vmProc, entry.Name(), "cgroup"))
		if err != nil {
			continue
		}
		service := serviceOfCgroup(string(cgroup))
		if service == "" || service == guardContainer {
			continue
		}
		status, err := os.ReadFile(filepath.Join(vmProc, entry.Name(), "status"))
		if err != nil {
			continue
		}
		name, rss := processStatus(string(status))
		if rss > largest[service].bytes {
			largest[service] = processMemory{pid: pid, name: name, bytes: rss}
		}
	}
	return largest
}
