/// napbox 自己放进环境里的容器。它们和服务的容器在同一个 pod 里，名字不能重，
/// 所以服务不能叫这些名字（ComposeBuilder 读 compose 时检查）。
public enum InternalContainers {
    /// 网络小容器（NapboxRuntime 的 GuardContainer；guard/runtime.go 的 guardContainer 要和它一致）
    public static let guardName = "napbox-guard"
    /// 放 runc 那块盘算作的容器（NapboxRuntime 的 RuntimeContainer）
    public static let runtimeName = "napbox-runtime"
    public static let names: Set<String> = [guardName, runtimeName]
}
