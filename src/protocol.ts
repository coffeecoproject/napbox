// napboxd 本地 socket 协议的 TypeScript 这一份，对应 native/Sources/NapboxProtocol/Protocol.swift。
// 类型都由 schema 推出来，发回的内容也按同一份 schema 核对，类型和实际校验不会各写各的；
// 这份和 Swift 对不对得上由 test/contract.test.ts 逐字段比较。字段含义看 Protocol.swift，这里不重复。
import { z } from "zod";

const isoDate = z.iso.datetime();
const base64 = z.base64();

/** 错误码，napboxd 原样给什么这里就是什么 */
export const errorCodes = [
  "daemon_unavailable",
  "bad_request",
  "unknown_method",
  "protocol_error",
  "usage_error",
  "internal_error",
  "compose_not_found",
  "compose_invalid",
  "compose_unsupported",
  "not_in_repository",
  "port_unavailable",
  "state_corrupted",
  "environment_not_found",
  "runtime_unavailable",
  "image_unavailable",
  "image_build_failed",
  "service_failed",
  "service_not_found",
  "volume_not_found",
  "snapshot_not_found",
  "healthcheck_timeout",
  "address_unavailable",
  "name_taken",
  "owner_mismatch",
] as const;
export type ErrorCode = (typeof errorCodes)[number];

export const methods = {
  status: "status",
  up: "up",
  down: "down",
  sleep: "sleep",
  egress: "egress",
  environment: "environment",
  logs: "logs",
  exec: "exec",
  subscribe: "subscribe",
  run: "run",
  reset: "reset",
  create: "create",
  wake: "wake",
  runs: "runs",
} as const;

// code 不收窄成 errorCodes：新版 napboxd 加的错误码也要原样带给调用方
export const NapboxErrorBody = z.object({ code: z.string(), message: z.string() });

export const EnvironmentState = z.enum(["running", "sleeping"]);
export const EgressMode = z.enum(["open", "none"]);
export const ServiceExitRestart = z.enum(["none", "restarting", "gave_up"]);
export const RunPurpose = z.enum(["up", "wake", "reset", "restart"]);
export const Readiness = z.enum(["healthcheck", "port", "process"]);
export const RootfsSource = z.enum(["unpacked", "cloned", "reused"]);
export const OutputStream = z.enum(["stdout", "stderr"]);
export const EventKind = z.enum([
  "started",
  "start_failed",
  "slept",
  "service_exited",
  "destroyed",
]);
export const SleepReason = z.enum(["idle", "request", "host_address", "shutdown", "vm_lost"]);

export const PortInfo = z.object({
  service: z.string(),
  containerPort: z.int(),
  hostPort: z.int(),
  variable: z.string(),
});

export const HostPortInfo = z.object({
  name: z.string(),
  hostPort: z.int(),
  variable: z.string(),
});

export const ServiceExit = z.object({
  service: z.string(),
  exitCode: z.int(),
  at: isoDate,
  restart: ServiceExitRestart,
});

/** 从哪个环境的快照复制了哪些数据卷（x-napbox.seed、reset 的 from） */
export const SeedSource = z.object({
  environment: z.string(),
  takenAt: isoDate,
  volumes: z.array(z.string()),
});

export const EnvironmentInfo = z.object({
  name: z.string(),
  owner: z.string().optional(),
  state: EnvironmentState,
  worktree: z.string(),
  ports: z.array(PortInfo),
  hostPorts: z.array(HostPortInfo),
  egress: EgressMode,
  variables: z.record(z.string(), z.string()),
  unsetVariables: z.array(z.string()),
  lastError: z.string().optional(),
  watchError: z.string().optional(),
  /** 声明了 x-napbox.seed 的开发环境，最近一次停下没拍成快照的说明；下次拍成了就没有 */
  snapshotError: z.string().optional(),
  serviceExits: z.array(ServiceExit),
  /** 只在这次 up、reset 起环境之前从别的环境的快照复制了数据时才有 */
  seededFrom: SeedSource.optional(),
});

export const StatusResult = z.object({
  version: z.string(),
  pid: z.int(),
  startedAt: isoDate,
  environments: z.array(EnvironmentInfo),
});

/** 操作哪个环境：worktree 持有的写 `{ cwd }`（它的临时环境再带上 `temp`），调用方持有的写 `{ name, owner }` */
export const EnvironmentTarget = z.union([
  z.object({ cwd: z.string(), temp: z.string().optional() }),
  z.object({ name: z.string(), owner: z.string() }),
]);

export const UpParams = z.object({
  cwd: z.string(),
  files: z.array(z.string()),
  profiles: z.array(z.string()),
  environment: z.record(z.string(), z.string()),
  build: z.boolean(),
  temp: z.string().optional(),
});

export const RunParams = z.object({
  cwd: z.string(),
  files: z.array(z.string()),
  profiles: z.array(z.string()),
  environment: z.record(z.string(), z.string()),
  build: z.boolean(),
  egress: EgressMode.optional(),
  service: z.string(),
  command: z.array(z.string()),
  noDeps: z.boolean(),
});

export const EnvironmentParams = z.object({ target: EnvironmentTarget });
export const DownParams = z.object({ target: EnvironmentTarget, discardData: z.boolean().optional() });

export const CreateParams = z.object({
  name: z.string(),
  owner: z.string(),
  directory: z.string(),
  files: z.array(z.string()),
  profiles: z.array(z.string()),
  environment: z.record(z.string(), z.string()),
  egress: EgressMode.optional(),
});

/** from：不写换成空的；写了换成那个目录所在 worktree 的开发环境最新快照里的那份 */
export const ResetParams = z.object({ target: EnvironmentTarget, volumes: z.array(z.string()), from: z.string().optional() });
export const EgressParams = z.object({ target: EnvironmentTarget, mode: EgressMode });

export const DownResult = z.object({
  name: z.string(),
  releasedPorts: z.array(z.int()),
  keptDataAt: z.string().optional(),
});

export const StreamOutput = z.object({ stream: OutputStream, data: base64 });
export const StdinMessage = z.object({ data: base64.optional(), end: z.boolean().optional() });

export const LogsParams = z.object({
  target: EnvironmentTarget,
  service: z.string(),
  tail: z.int().optional(),
  follow: z.boolean(),
});
export const LogsResult = z.object({ ended: z.string().optional() });

export const ExecParams = z.object({
  target: EnvironmentTarget,
  service: z.string(),
  command: z.array(z.string()),
  /** 最多跑多久，从命令开始跑算起（唤醒的时间不算）；不写是一直等。到时 napboxd 结束命令和它的子进程，确认结束了才返回（timedOut） */
  timeoutSeconds: z.int().positive().optional(),
});
/** timedOut：到了 timeoutSeconds 被结束的，exitCode 是结束后的退出码（一般是 137） */
export const ExecResult = z.object({ exitCode: z.int(), timedOut: z.literal(true).optional() });

export const ServiceRun = z.object({
  service: z.string(),
  image: z.string(),
  digest: z.string(),
  platformDigest: z.string(),
  skipped: z.boolean(),
  startedAt: isoDate.optional(),
  readyAt: isoDate.optional(),
  readiness: Readiness.optional(),
  rootfs: RootfsSource.optional(),
});

export const RunRecord = z.object({
  id: z.string(),
  environment: z.string(),
  purpose: RunPurpose,
  startedAt: isoDate,
  finishedAt: isoDate,
  error: NapboxErrorBody.optional(),
  definitionDigest: z.string(),
  egress: EgressMode,
  ports: z.array(PortInfo),
  services: z.array(ServiceRun),
  seededFrom: SeedSource.optional(),
});

export const RunsResult = z.object({ runs: z.array(RunRecord) });

export const SubscribeParams = z.object({
  owner: z.string().optional(),
  names: z.array(z.string()).optional(),
});

export const EnvironmentEvent = z.object({
  at: isoDate,
  environment: z.string(),
  owner: z.string().optional(),
  type: EventKind,
  purpose: RunPurpose.optional(),
  runId: z.string().optional(),
  error: NapboxErrorBody.optional(),
  sleepReason: SleepReason.optional(),
  reason: z.string().optional(),
  service: z.string().optional(),
  exitCode: z.int().optional(),
  restart: ServiceExitRestart.optional(),
});

/** subscribe 正常结束时的结果（调用方先断开写端才会有，这个客户端不这样断开） */
export const EmptyResult = z.object({});

export const Request = z.object({
  id: z.int(),
  method: z.string(),
  params: z.unknown().optional(),
});

export const Response = z.object({
  id: z.int(),
  result: z.unknown().optional(),
  error: NapboxErrorBody.optional(),
  output: StreamOutput.optional(),
  subscribed: z.boolean().optional(),
  event: EnvironmentEvent.optional(),
});

export type Response = z.infer<typeof Response>;
export type EnvironmentState = z.infer<typeof EnvironmentState>;
export type EgressMode = z.infer<typeof EgressMode>;
export type ServiceExitRestart = z.infer<typeof ServiceExitRestart>;
export type RunPurpose = z.infer<typeof RunPurpose>;
export type Readiness = z.infer<typeof Readiness>;
export type OutputStream = z.infer<typeof OutputStream>;
export type EventKind = z.infer<typeof EventKind>;
export type SleepReason = z.infer<typeof SleepReason>;
export type NapboxErrorBody = z.infer<typeof NapboxErrorBody>;
export type PortInfo = z.infer<typeof PortInfo>;
export type HostPortInfo = z.infer<typeof HostPortInfo>;
export type ServiceExit = z.infer<typeof ServiceExit>;
export type EnvironmentInfo = z.infer<typeof EnvironmentInfo>;
export type StatusResult = z.infer<typeof StatusResult>;
export type EnvironmentTarget = z.infer<typeof EnvironmentTarget>;
export type UpParams = z.infer<typeof UpParams>;
export type RunParams = z.infer<typeof RunParams>;
export type CreateParams = z.infer<typeof CreateParams>;
export type DownParams = z.infer<typeof DownParams>;
export type DownResult = z.infer<typeof DownResult>;
export type LogsResult = z.infer<typeof LogsResult>;
export type ExecResult = z.infer<typeof ExecResult>;
export type ServiceRun = z.infer<typeof ServiceRun>;
export type SeedSource = z.infer<typeof SeedSource>;
export type RunRecord = z.infer<typeof RunRecord>;
export type RunsResult = z.infer<typeof RunsResult>;
export type SubscribeParams = z.infer<typeof SubscribeParams>;
export type EnvironmentEvent = z.infer<typeof EnvironmentEvent>;
