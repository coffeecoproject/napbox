// 把 agent 要运行的 shell 命令拆成一条条简单命令，给钩子判断用。只为分清“真的在运行 docker compose up”
// 和“只是引号里提到它”（比如 git commit -m "docker compose up"），不是完整的 shell 解析器；
// 变量、通配符不展开，看不懂的一律当普通单词，宁可放过，不误拦。
export interface SimpleCommand {
  argv: string[];
  /** 这条命令之前出现过的 cd 的目标（只认字面路径），按顺序；相对路径相对于前一个 */
  cds: string[];
}

type Token = { word: string } | { operator: true };

const OPERATOR_CHARACTERS = new Set([";", "&", "|", "\n", "(", ")", "`"]);

function tokenize(command: string): Token[] {
  const tokens: Token[] = [];
  let word: string | undefined;
  const flush = () => {
    if (word !== undefined) tokens.push({ word });
    word = undefined;
  };
  for (let i = 0; i < command.length; i++) {
    const c = command[i] as string;
    if (c === "\\") {
      i++;
      if (command[i] !== "\n") word = (word ?? "") + (command[i] ?? "");
    } else if (c === "'") {
      const end = command.indexOf("'", i + 1);
      const stop = end < 0 ? command.length : end;
      word = (word ?? "") + command.slice(i + 1, stop);
      i = stop;
    } else if (c === '"') {
      word ??= "";
      for (i++; i < command.length && command[i] !== '"'; i++) {
        if (command[i] === "\\" && i + 1 < command.length) i++;
        word += command[i];
      }
    } else if (c === "$" && command[i + 1] === "(") {
      flush();
      tokens.push({ operator: true });
      i++;
    } else if (OPERATOR_CHARACTERS.has(c)) {
      flush();
      tokens.push({ operator: true });
    } else if (c === " " || c === "\t") {
      flush();
    } else if (c === "#" && word === undefined) {
      while (i + 1 < command.length && command[i + 1] !== "\n") i++;
    } else {
      word = (word ?? "") + c;
    }
  }
  flush();
  return tokens;
}

/** 这些命令后面跟的才是真正运行的命令；值是它们自己带参数的选项 */
const WRAPPERS = new Map<string, Set<string>>([
  ["sudo", new Set(["-u", "-g", "-h", "-p", "-C", "-T", "-U"])],
  ["env", new Set(["-u", "-C", "-S"])],
  ["command", new Set()],
  ["exec", new Set(["-a"])],
  ["nohup", new Set()],
  ["time", new Set()],
  ["nice", new Set(["-n"])],
]);
const SHELLS = new Set(["sh", "bash", "zsh", "dash"]);

const baseName = (word: string) => word.slice(word.lastIndexOf("/") + 1);
const isAssignment = (word: string) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(word);

/** 去掉变量赋值和 sudo、env 这类前缀，剩下真正运行的命令 */
function unwrap(argv: string[]): string[] {
  let rest = argv;
  for (;;) {
    while (rest[0] !== undefined && isAssignment(rest[0])) rest = rest.slice(1);
    const name = rest[0] === undefined ? undefined : baseName(rest[0]);
    if (name === "timeout") {
      let i = 1;
      while (rest[i]?.startsWith("-")) i++;
      rest = rest.slice(i + 1); // 跳过时长
      continue;
    }
    const options = name === undefined ? undefined : WRAPPERS.get(name);
    if (!options) return rest;
    let i = 1;
    while (rest[i]?.startsWith("-")) i += options.has(rest[i] as string) ? 2 : 1;
    rest = rest.slice(i);
  }
}

/** 拆成简单命令。sh -c '...' 里的内容也拆开看 */
export function simpleCommands(command: string, depth = 0): SimpleCommand[] {
  const commands: SimpleCommand[] = [];
  const cds: string[] = [];
  let argv: string[] = [];
  const finish = () => {
    const words = unwrap(argv);
    argv = [];
    const name = words[0] === undefined ? undefined : baseName(words[0]);
    if (name === undefined) return;
    if (name === "cd") {
      const target = words[1];
      if (target && target !== "-" && !target.includes("$")) cds.push(target);
      return;
    }
    const script = SHELLS.has(name) ? shellScript(words) : undefined;
    if (script !== undefined && depth < 3) {
      for (const inner of simpleCommands(script, depth + 1))
        commands.push({ argv: inner.argv, cds: [...cds, ...inner.cds] });
      return;
    }
    commands.push({ argv: words, cds: [...cds] });
  };
  for (const token of tokenize(command)) {
    if ("word" in token) argv.push(token.word);
    else finish();
  }
  finish();
  return commands;
}

/** sh -c、bash -lc 这类写法里 -c 后面的脚本 */
function shellScript(words: string[]): string | undefined {
  for (let i = 1; i < words.length; i++) {
    const word = words[i] as string;
    if (!word.startsWith("-")) return undefined;
    if (!word.startsWith("--") && word.includes("c")) return words[i + 1];
  }
  return undefined;
}

/** docker 和 docker compose 自己带值的选项，子命令在它们后面 */
const DOCKER_OPTIONS = new Set(["--config", "-c", "--context", "-H", "--host", "-l", "--log-level"]);
const COMPOSE_OPTIONS = new Set([
  "--ansi",
  "--env-file",
  "-f",
  "--file",
  "--parallel",
  "--profile",
  "--progress",
  "--project-directory",
  "-p",
  "--project-name",
]);

function firstWordAfterOptions(words: string[], options: Set<string>): number {
  let i = 0;
  while (words[i]?.startsWith("-")) i += options.has(words[i] as string) ? 2 : 1;
  return i;
}

/** docker 自己的选项之后的词，第一个是子命令；不是 docker 命令时是 undefined */
function dockerWords(argv: string[]): string[] | undefined {
  if (argv[0] === undefined || baseName(argv[0]) !== "docker") return undefined;
  const rest = argv.slice(1);
  return rest.slice(firstWordAfterOptions(rest, DOCKER_OPTIONS));
}

/** docker compose 的子命令，不是 docker compose 时是 undefined */
export function composeSubcommand(argv: string[]): string | undefined {
  let rest: string[];
  if (argv[0] !== undefined && baseName(argv[0]) === "docker-compose") {
    rest = argv.slice(1);
  } else {
    const words = dockerWords(argv);
    if (words?.[0] !== "compose") return undefined;
    rest = words.slice(1);
  }
  const i = firstWordAfterOptions(rest, COMPOSE_OPTIONS);
  if (rest.includes("--help") || rest.includes("-h")) return undefined;
  return rest[i];
}

/** 是不是 docker run（或者同一件事的另一种写法 docker container run）：不靠 compose 直接起一个容器 */
export function isDockerRun(argv: string[]): boolean {
  const words = dockerWords(argv);
  if (words === undefined || words.includes("--help")) return false;
  return words[0] === "run" || (words[0] === "container" && words[1] === "run");
}

/** 自己在宿主机上起数据库这类服务的命令，返回一句话描述；不是时返回 undefined */
export function startsOwnService(argv: string[]): string | undefined {
  const name = argv[0] === undefined ? undefined : baseName(argv[0]);
  switch (name) {
    case "postgres":
    case "mysqld":
    case "mysqld_safe":
    case "mongod":
    case "redis-server":
      return argv.includes("--version") || argv.includes("--help") ? undefined : name;
    case "pg_ctl":
    case "mysql.server":
      return argv.includes("start") || argv.includes("restart") ? name : undefined;
    case "minio":
      return argv[1] === "server" ? "minio server" : undefined;
    case "brew":
      return argv[1] === "services" && (argv[2] === "start" || argv[2] === "run" || argv[2] === "restart")
        ? "brew services"
        : undefined;
    default:
      return undefined;
  }
}
