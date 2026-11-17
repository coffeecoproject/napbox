package main

import (
	"strconv"
	"strings"
	"time"
)

// 怎么判断服务卡在内存上、该结束哪个进程（memwatch.go 读数据，这里只算）。

const (
	// 内存压力 full avg10 到这么多算卡住：过去 10 秒里这个服务的进程有这么多比例的时间全都在等内存。
	// 卡住时几秒内到 30 以上（实测 1G 上限的 node 到顶后 7 秒 25、14 秒 40，之后 50 上下），平时是 0
	stallPercent = 30.0
	// 连着这么多次（每秒一次）都到了才算，一次偶然的高峰不算
	stallSamples = 2
	// 离上限还差这么多以内算到了自己的上限
	limitMargin = 64 << 20
	// 处理过一次后等这么久再看：avg10 是 10 秒的平均，结束了进程也要过一阵才落下来
	memoryCooldown = 15 * time.Second
)

type serviceMemory struct {
	name    string
	stalled float64 // memory.pressure 的 full avg10
	current uint64
	limit   uint64 // 0 是没有自己的上限（memory.max 写着 max）
}

type processMemory struct {
	pid   int
	name  string
	bytes uint64
}

// 报给 napboxd 的：结束哪个进程、为什么
type memoryReport struct {
	// 卡住的服务
	Service string `json:"service"`
	// service：到了它自己的上限，结束它里面占内存最多的进程；
	// environment：没到自己的上限，是整个环境的内存用完了，结束所有服务里占内存最多的进程
	Scope      string  `json:"scope"`
	LimitBytes uint64  `json:"limitBytes"`
	Pressure   float64 `json:"pressure"`
	// 要结束的进程：所在的服务、虚拟机里的进程号、名字、占的内存（VmRSS）
	TargetService string `json:"targetService"`
	PID           int    `json:"pid"`
	Process       string `json:"process"`
	ProcessBytes  uint64 `json:"processBytes"`
}

type memoryWatcher struct {
	strikes map[string]int
	quiet   time.Time
}

func newMemoryWatcher() *memoryWatcher {
	return &memoryWatcher{strikes: map[string]int{}}
}

// 看一次各服务的内存。有服务连着卡住时给出要结束的进程；processes 只在要结束时才去读（要扫一遍虚拟机的 /proc）。
func (w *memoryWatcher) observe(now time.Time, services []serviceMemory, processes func() map[string]processMemory) (memoryReport, bool) {
	var stuck *serviceMemory
	for i, s := range services {
		if s.stalled >= stallPercent {
			w.strikes[s.name]++
		} else {
			delete(w.strikes, s.name)
		}
		if w.strikes[s.name] >= stallSamples && (stuck == nil || s.stalled > stuck.stalled) {
			stuck = &services[i]
		}
	}
	if stuck == nil || now.Before(w.quiet) {
		return memoryReport{}, false
	}
	largest := processes()
	report := memoryReport{Service: stuck.name, LimitBytes: stuck.limit, Pressure: stuck.stalled}
	var target processMemory
	if stuck.limit > 0 && stuck.current+limitMargin >= stuck.limit {
		report.Scope = "service"
		report.TargetService = stuck.name
		target = largest[stuck.name]
	} else {
		report.Scope = "environment"
		for service, p := range largest {
			if p.bytes > target.bytes {
				report.TargetService, target = service, p
			}
		}
	}
	if target.pid == 0 {
		return memoryReport{}, false
	}
	report.PID, report.Process, report.ProcessBytes = target.pid, target.name, target.bytes
	w.strikes = map[string]int{}
	w.quiet = now.Add(memoryCooldown)
	return report, true
}

// memory.pressure 里 full 那一行的 avg10
func fullAvg10(content string) float64 {
	for _, line := range strings.Split(content, "\n") {
		rest, ok := strings.CutPrefix(line, "full ")
		if !ok {
			continue
		}
		for _, field := range strings.Fields(rest) {
			if value, ok := strings.CutPrefix(field, "avg10="); ok {
				n, _ := strconv.ParseFloat(value, 64)
				return n
			}
		}
	}
	return 0
}

// /proc/<进程>/cgroup 说它在哪个服务的容器里（从网络小容器看是 "/../<容器名>"，procinfo.go），不在任何容器里的是空
func serviceOfCgroup(content string) string {
	for _, line := range strings.Split(content, "\n") {
		path, ok := strings.CutPrefix(line, "0::/../")
		if !ok {
			continue
		}
		name, _, _ := strings.Cut(path, "/")
		return name
	}
	return ""
}

// /proc/<进程>/status 里的名字和 VmRSS（字节）
func processStatus(content string) (string, uint64) {
	var name string
	var rss uint64
	for _, line := range strings.Split(content, "\n") {
		if v, ok := strings.CutPrefix(line, "Name:"); ok {
			name = strings.TrimSpace(v)
		} else if v, ok := strings.CutPrefix(line, "VmRSS:"); ok {
			kb, _ := strconv.ParseUint(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(v), "kB")), 10, 64)
			rss = kb << 10
		}
	}
	return name, rss
}

// memory.current、memory.max 的值（字节）。memory.max 写着 max 是没有上限，算 0：
// 没写上限的服务 napboxd 让它就是 max（ContainerPlan），写了的才是一个数
func memoryValue(content string) (uint64, error) {
	content = strings.TrimSpace(content)
	if content == "max" {
		return 0, nil
	}
	return strconv.ParseUint(content, 10, 64)
}
