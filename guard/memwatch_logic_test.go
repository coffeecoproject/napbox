package main

import (
	"testing"
	"time"
)

func TestFullAvg10(t *testing.T) {
	content := "some avg10=61.20 avg60=20.00 avg300=5.00 total=100\nfull avg10=54.50 avg60=19.66 avg300=4.74 total=15098614\n"
	if got := fullAvg10(content); got != 54.5 {
		t.Errorf("fullAvg10 = %v，应该是 54.5", got)
	}
	if got := fullAvg10(""); got != 0 {
		t.Errorf("空内容 = %v，应该是 0", got)
	}
}

func TestServiceOfCgroup(t *testing.T) {
	cases := map[string]string{
		"0::/../browser\n":            "browser",
		"0::/../browser/init.scope\n": "browser",
		"0::/\n":                      "",
		"":                            "",
	}
	for content, want := range cases {
		if got := serviceOfCgroup(content); got != want {
			t.Errorf("serviceOfCgroup(%q) = %q，应该是 %q", content, got, want)
		}
	}
}

func TestProcessStatus(t *testing.T) {
	name, rss := processStatus("Name:\tchrome\nUmask:\t0022\nVmRSS:\t  548000 kB\nRssAnon:\t 500000 kB\n")
	if name != "chrome" || rss != 548000<<10 {
		t.Errorf("processStatus = %q %d", name, rss)
	}
}

func TestMemoryWatcher(t *testing.T) {
	const mb = 1 << 20
	processes := func() map[string]processMemory {
		return map[string]processMemory{
			"browser":  {pid: 301, name: "chrome", bytes: 540 * mb},
			"postgres": {pid: 120, name: "postgres", bytes: 900 * mb},
		}
	}
	at := time.Unix(1000, 0)
	stuckAtLimit := []serviceMemory{
		{name: "browser", stalled: 45, current: 2048*mb - 1*mb, limit: 2048 * mb},
		{name: "postgres", stalled: 0, current: 900 * mb},
	}

	t.Run("一次不算", func(t *testing.T) {
		w := newMemoryWatcher()
		if _, ok := w.observe(at, stuckAtLimit, processes); ok {
			t.Fatal("第一次就报了")
		}
	})

	t.Run("到了自己的上限：结束它里面最大的", func(t *testing.T) {
		w := newMemoryWatcher()
		w.observe(at, stuckAtLimit, processes)
		report, ok := w.observe(at.Add(time.Second), stuckAtLimit, processes)
		if !ok || report.Scope != "service" || report.TargetService != "browser" || report.PID != 301 {
			t.Fatalf("得到 %+v %v", report, ok)
		}
		// 刚处理过：avg10 还没落下来，不再结束别的
		w.observe(at.Add(2*time.Second), stuckAtLimit, processes)
		if _, ok := w.observe(at.Add(3*time.Second), stuckAtLimit, processes); ok {
			t.Fatal("冷却期间又报了")
		}
		if _, ok := w.observe(at.Add(20*time.Second), stuckAtLimit, processes); !ok {
			t.Fatal("冷却过了还卡着，应该再报")
		}
	})

	t.Run("没到自己的上限：整个环境用完了，结束所有服务里最大的", func(t *testing.T) {
		w := newMemoryWatcher()
		shared := []serviceMemory{
			{name: "browser", stalled: 40, current: 3000 * mb},
			{name: "postgres", stalled: 35, current: 900 * mb},
		}
		w.observe(at, shared, processes)
		report, ok := w.observe(at.Add(time.Second), shared, processes)
		if !ok || report.Scope != "environment" || report.Service != "browser" || report.TargetService != "postgres" || report.PID != 120 {
			t.Fatalf("得到 %+v %v", report, ok)
		}
	})

	t.Run("中间缓过来一次就重新数", func(t *testing.T) {
		w := newMemoryWatcher()
		calm := []serviceMemory{{name: "browser", stalled: 5, current: 100 * mb, limit: 2048 * mb}}
		w.observe(at, stuckAtLimit, processes)
		w.observe(at.Add(time.Second), calm, processes)
		if _, ok := w.observe(at.Add(2*time.Second), stuckAtLimit, processes); ok {
			t.Fatal("中间缓过来了还报")
		}
	})

	t.Run("找不到进程不报", func(t *testing.T) {
		w := newMemoryWatcher()
		none := func() map[string]processMemory { return nil }
		w.observe(at, stuckAtLimit, none)
		if _, ok := w.observe(at.Add(time.Second), stuckAtLimit, none); ok {
			t.Fatal("没有进程也报了")
		}
	})
}

func TestMemoryValue(t *testing.T) {
	if got, err := memoryValue("max\n"); got != 0 || err != nil {
		t.Errorf("max = %d %v，应该是 0", got, err)
	}
	if got, err := memoryValue("1073741824\n"); got != 1<<30 || err != nil {
		t.Errorf("1073741824 = %d %v", got, err)
	}
	if _, err := memoryValue(""); err == nil {
		t.Error("空的应该报错")
	}
}
