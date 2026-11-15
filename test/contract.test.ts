// 拿 Protocol.swift 和 src/protocol.ts 逐字段比较：字段名、类型、是否可选、枚举取值、方法名和错误码。
// 不用起 napboxd，也覆盖真实运行很难碰到的字段和取值（比如 gave_up、host_address）。
// Swift 改了协议、TypeScript 没跟上（或者反过来）时，这里失败。
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { z } from "zod";
import { NapboxClient } from "../src/client.ts";
import * as protocol from "../src/protocol.ts";

const swiftFile = new URL("../native/Sources/NapboxProtocol/Protocol.swift", import.meta.url);

interface SwiftField {
  name: string;
  type: string;
  optional: boolean;
}
type SwiftType =
  | { kind: "struct"; fields: SwiftField[] }
  | { kind: "enum"; cases: string[]; constants: Map<string, string> };

/** 按缩进和大括号读 Protocol.swift 里的 public struct、public enum。键是带外层的名字，如 ServiceExit.Restart */
function parseSwift(source: string): Map<string, SwiftType> {
  const types = new Map<string, SwiftType>();
  const stack: { name: string; depth: number }[] = [];
  let depth = 0;
  for (const raw of source.split("\n")) {
    const line = raw.replace(/\/\/.*$/, "").trim();
    const opened = line.match(/^public (struct|enum) (\w+)/);
    if (opened) {
      const name = [...stack.map((s) => s.name), opened[2]].join(".");
      types.set(
        name,
        opened[1] === "struct"
          ? { kind: "struct", fields: [] }
          : { kind: "enum", cases: [], constants: new Map() },
      );
      stack.push({ name: opened[2] as string, depth });
    } else {
      const owner = types.get(stack.map((s) => s.name).join("."));
      const field = line.match(/^public var (\w+): (.+?)(\?)?$/);
      const enumCase = line.match(/^case (\w+)(?: = "([^"]+)")?$/);
      const constant = line.match(/^public static let (\w+) = "([^"]+)"$/);
      if (owner?.kind === "struct" && field) {
        owner.fields.push({
          name: field[1] as string,
          type: field[2] as string,
          optional: field[3] !== undefined,
        });
      } else if (owner?.kind === "enum" && enumCase) {
        owner.cases.push(enumCase[2] ?? (enumCase[1] as string));
      } else if (owner?.kind === "enum" && constant) {
        owner.constants.set(constant[1] as string, constant[2] as string);
      }
    }
    depth += (line.match(/\{/g) ?? []).length - (line.match(/\}/g) ?? []).length;
    while (stack.length > 0 && depth <= (stack.at(-1) as { depth: number }).depth) stack.pop();
  }
  return types;
}

const swift = parseSwift(readFileSync(swiftFile, "utf8"));

// EnvironmentTarget 在 Swift 里是自己写的编解码，JSONValue 是任意 JSON，都读不出字段，直接写出它们在线路上的样子
const handWritten = new Map([
  ["EnvironmentTarget", "({cwd:String,temp?:String}|{name:String,owner:String})"],
  ["JSONValue", "Any"],
]);

/** Swift 类型展开成一个能比较的字符串 */
function describeSwift(type: string, scope: string): string {
  const special = handWritten.get(type);
  if (special) return special;
  const map = type.match(/^\[String: (.+)\]$/);
  if (map) return `[String:${describeSwift(map[1] as string, scope)}]`;
  const list = type.match(/^\[(.+)\]$/);
  if (list) return `[${describeSwift(list[1] as string, scope)}]`;
  if (type === "Int" || type === "Int32") return "Int";
  if (["String", "Bool", "Date", "Data"].includes(type)) return type;
  const found = swift.get(`${scope}.${type}`) ?? swift.get(type);
  const name = swift.has(`${scope}.${type}`) ? `${scope}.${type}` : type;
  assert.ok(found, `Protocol.swift 里找不到类型 ${type}`);
  if (found.kind === "enum") return `(${[...found.cases].sort().join("|")})`;
  const fields = found.fields
    .map((f) => `${f.name}${f.optional ? "?" : ""}:${describeSwift(f.type, name)}`)
    .sort();
  return `{${fields.join(",")}}`;
}

interface JsonSchema {
  type?: string;
  format?: string;
  contentEncoding?: string;
  enum?: string[];
  anyOf?: JsonSchema[];
  items?: JsonSchema;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  additionalProperties?: JsonSchema | boolean;
}

/** zod schema 展开成同样格式的字符串 */
function describeSchema(schema: JsonSchema): string {
  if (schema.enum) return `(${[...schema.enum].sort().join("|")})`;
  if (schema.anyOf) return `(${schema.anyOf.map(describeSchema).join("|")})`;
  switch (schema.type) {
    case undefined:
      return "Any";
    case "string":
      if (schema.format === "date-time") return "Date";
      if (schema.contentEncoding === "base64") return "Data";
      return "String";
    case "integer":
      return "Int";
    case "boolean":
      return "Bool";
    case "array":
      return `[${describeSchema(schema.items as JsonSchema)}]`;
    case "object": {
      if (!schema.properties) {
        return `[String:${describeSchema(schema.additionalProperties as JsonSchema)}]`;
      }
      const fields = Object.entries(schema.properties)
        .map(([name, value]) => {
          const optional = schema.required?.includes(name) ? "" : "?";
          return `${name}${optional}:${describeSchema(value)}`;
        })
        .sort();
      return `{${fields.join(",")}}`;
    }
    default:
      throw new Error(`没有处理的 JSON schema 类型：${schema.type}`);
  }
}

function describeZod(schema: z.ZodType): string {
  return describeSchema(z.toJSONSchema(schema, { unrepresentable: "any" }) as JsonSchema);
}

// Swift 类型 → TS 里对应的 schema。Protocol.swift 新加协议类型时这里也要加，否则下面第一条就失败
const counterparts: Record<string, z.ZodType> = {
  Request: protocol.Request,
  Response: protocol.Response,
  NapboxError: protocol.NapboxErrorBody,
  StatusResult: protocol.StatusResult,
  EnvironmentState: protocol.EnvironmentState,
  EgressMode: protocol.EgressMode,
  EnvironmentInfo: protocol.EnvironmentInfo,
  PortInfo: protocol.PortInfo,
  SeedSource: protocol.SeedSource,
  HostPortInfo: protocol.HostPortInfo,
  UpParams: protocol.UpParams,
  RunParams: protocol.RunParams,
  EnvironmentParams: protocol.EnvironmentParams,
  DownParams: protocol.DownParams,
  CreateParams: protocol.CreateParams,
  ServiceExit: protocol.ServiceExit,
  "ServiceExit.Restart": protocol.ServiceExitRestart,
  ResetParams: protocol.ResetParams,
  EgressParams: protocol.EgressParams,
  DownResult: protocol.DownResult,
  StreamOutput: protocol.StreamOutput,
  "StreamOutput.Stream": protocol.OutputStream,
  StdinMessage: protocol.StdinMessage,
  LogsParams: protocol.LogsParams,
  LogsResult: protocol.LogsResult,
  ExecParams: protocol.ExecParams,
  ExecResult: protocol.ExecResult,
  RunRecord: protocol.RunRecord,
  "RunRecord.Purpose": protocol.RunPurpose,
  ServiceRun: protocol.ServiceRun,
  "ServiceRun.Readiness": protocol.Readiness,
  "ServiceRun.Rootfs": protocol.RootfsSource,
  RunsResult: protocol.RunsResult,
  SubscribeParams: protocol.SubscribeParams,
  EnvironmentEvent: protocol.EnvironmentEvent,
  "EnvironmentEvent.Kind": protocol.EventKind,
  "EnvironmentEvent.SleepReason": protocol.SleepReason,
};

// 不是线路上的类型：路径、版本号、编码工具，以及单独比较的错误码、方法名和手写编解码的类型
const notOnWire = new Set([
  "NapboxVersion",
  "Paths",
  "Wire",
  "ErrorCode",
  "Method",
  "EnvironmentTarget",
]);

test("Protocol.swift 里每个线路类型 TypeScript 都有对应，没有多余的", () => {
  const wireTypes = [...swift.keys()].filter((name) => !notOnWire.has(name)).sort();
  assert.deepEqual(wireTypes, Object.keys(counterparts).sort());
});

for (const [name, schema] of Object.entries(counterparts)) {
  test(`${name} 的字段、类型、可选和取值都和 Swift 一样`, () => {
    const scope = name.includes(".") ? (name.split(".")[0] as string) : "";
    assert.equal(describeZod(schema), describeSwift(name.split(".").at(-1) as string, scope));
  });
}

test("EnvironmentTarget 按线路上的两种写法", () => {
  assert.equal(
    describeZod(protocol.EnvironmentTarget),
    handWritten.get("EnvironmentTarget"),
  );
});

test("错误码和 Swift 的 ErrorCode 一样", () => {
  const code = swift.get("ErrorCode");
  assert.equal(code?.kind, "enum");
  assert.deepEqual([...protocol.errorCodes].sort(), [...(code?.kind === "enum" ? code.cases : [])].sort());
});

test("方法名和 Swift 的 Method 一样", () => {
  const method = swift.get("Method");
  assert.equal(method?.kind, "enum");
  assert.deepEqual(
    Object.entries(protocol.methods).sort(),
    [...(method?.kind === "enum" ? method.constants : [])].sort(),
  );
});

test("每个方法客户端都有对应的调用", () => {
  const clientMethod: Record<keyof typeof protocol.methods, keyof NapboxClient> = {
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
  };
  for (const name of Object.values(clientMethod)) {
    assert.equal(typeof NapboxClient.prototype[name], "function", name);
  }
});

test("这个比较本身能发现不一致", () => {
  const changed = z.object({ ...protocol.PortInfo.shape, hostPort: z.string() });
  assert.notEqual(describeZod(changed), describeSwift("PortInfo", ""));
  const dropped = z.enum(["none", "restarting"]);
  assert.notEqual(describeZod(dropped), describeSwift("Restart", "ServiceExit"));
  const optional = protocol.PortInfo.partial();
  assert.notEqual(describeZod(optional), describeSwift("PortInfo", ""));
});
