//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// 垫在 vminitd 和 runc 中间的一层。同一个程序换个名字放在一块单独的盘上，
// 旁边是真的 runc 和 net.json；napboxd 让 vminitd 用它来启动容器（LinuxPod 的 ociRuntimePath），vminitd 以为自己在叫 runc。
//
// 只管一件事：建服务的容器（create）时给它一个自己的网络。先在容器的配置里加上网络命名空间，让 runc 把容器建出来
// （这时服务的程序还没开始跑），再把它接到虚拟机里的网桥上（network.go）。这些在 create 返回之前做完，
// vminitd 接着叫 start 时网络已经是好的。别的命令、还有网络小容器自己的 create，原样交给 runc：
// 网络小容器留在虚拟机的网络里，转发端口、加出网规则都要在那里做。
const (
	// 这个程序在那块盘上叫这个名字；按这个名字认出自己是在当 runc 用（main.go）
	runtimeProgram = "napbox-runc"
	// 网络小容器的名字，和 napboxd 的 GuardContainer.name 一致
	guardContainer = "napbox-guard"
	// 只为放 runc 那块盘的容器（不启动），和 napboxd 的 RuntimeContainer.name 一致
	runtimeContainer = "napbox-runtime"
)

// runc 自己失败了：它已经把原因写进日志，这里只把退出码带回去
type runcFailed int

func (code runcFailed) Error() string { return fmt.Sprintf("runc 退出码 %d", int(code)) }

// executable 是这个程序自己的路径，runc 和 net.json 在同一个目录
func runAsRuntime(executable string, args []string) {
	directory := filepath.Dir(executable)
	runc := filepath.Join(directory, "runc")
	id := ""
	if len(args) > 0 {
		id = args[len(args)-1]
	}
	var err error
	if runcSubcommand(args) != "create" || id == guardContainer {
		// 换成 runc 自己，成功了就不会回来
		err = syscall.Exec(runc, append([]string{runc}, args...), os.Environ())
	} else {
		err = createService(runc, directory, id, args)
	}
	var code runcFailed
	if errors.As(err, &code) {
		os.Exit(int(code))
	}
	if err != nil {
		reportLikeRunc(runcFlag(args, "--log"), err)
		os.Exit(1)
	}
}

func createService(runc, directory, service string, args []string) error {
	bundle, pidFile := runcFlag(args, "--bundle"), runcFlag(args, "--pid-file")
	if bundle == "" || pidFile == "" {
		return fmt.Errorf("create 没带 --bundle 或 --pid-file：%q", args)
	}
	content, err := os.ReadFile(filepath.Join(directory, "net.json"))
	if err != nil {
		return err
	}
	config, err := parseNetworkConfig(content)
	if err != nil {
		return err
	}
	network, err := config.network(service)
	if err != nil {
		return err
	}
	specPath := filepath.Join(bundle, "config.json")
	spec, err := os.ReadFile(specPath)
	if err != nil {
		return err
	}
	if spec, err = withNetworkNamespace(spec); err != nil {
		return fmt.Errorf("改 %s：%w", specPath, err)
	}
	if err := os.WriteFile(specPath, spec, 0o644); err != nil {
		return err
	}

	// 标准输入输出是容器的，原样交过去
	create := exec.Command(runc, args...)
	create.Stdin, create.Stdout, create.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := create.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return runcFailed(exit.ExitCode())
		}
		return err
	}

	err = connectCreated(network, pidFile)
	if err != nil {
		// 网络没接上就不能让它起来：把刚建的容器删掉，vminitd 看到的是 create 失败
		remove := []string{"delete", "--force", service}
		if root := runcFlag(args, "--root"); root != "" {
			remove = append([]string{"--root", root}, remove...)
		}
		_ = exec.Command(runc, remove...).Run()
		return fmt.Errorf("给 %s 接网络：%w", service, err)
	}
	return nil
}

// runc create 把容器 1 号进程在虚拟机里的进程号写在 pidFile 里
func connectCreated(network serviceNetwork, pidFile string) error {
	text, err := os.ReadFile(pidFile)
	if err != nil {
		return err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(text)))
	if err != nil {
		return fmt.Errorf("%s 的内容是 %q，不是进程号", pidFile, text)
	}
	return connectService(network, pid)
}

// vminitd 不看 runc 的标准错误（那是容器的输出），只读 --log 那个文件里 JSON 格式的日志，把 error 级别的 msg 报给 napboxd。
// 这里的失败照同样的格式写进去，napboxd 报的错里才有原因。没给 --log 就写到标准错误。
func reportLikeRunc(logPath string, failure error) {
	message := runtimeProgram + "：" + failure.Error()
	if logPath != "" {
		line, _ := json.Marshal(map[string]string{"level": "error", "msg": message, "time": time.Now().UTC().Format(time.RFC3339)})
		if file, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			_, err = file.Write(append(line, '\n'))
			file.Close()
			if err == nil {
				return
			}
		}
	}
	fmt.Fprintln(os.Stderr, message)
}
