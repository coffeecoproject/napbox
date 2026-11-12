// vm.test.ts 的「x86 的程序」用：编成 linux/amd64，放进 arm64 的虚拟机里跑。
// 输出自己是给哪种芯片编的；带参数 stay 时不退出（当服务的主程序）。
package main

import (
	"fmt"
	"os"
	"runtime"
	"time"
)

func main() {
	fmt.Println("arch=" + runtime.GOARCH)
	if len(os.Args) > 1 && os.Args[1] == "stay" {
		for {
			time.Sleep(time.Hour)
		}
	}
}
