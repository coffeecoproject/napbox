// 演示后端：一页笔记，存在 PostgreSQL；访问次数记在 Redis。
import http from "node:http";
import postgres from "postgres";
import { createClient } from "redis";

for (const name of ["DATABASE_URL", "REDIS_URL", "PUBLIC_ADDRESS"]) {
  if (!process.env[name]) {
    console.error(`缺少环境变量 ${name}`);
    process.exit(1);
  }
}

const sql = postgres(process.env.DATABASE_URL);
// node-redis 要求监听 error：没有监听时连接出错会让进程崩掉
const redis = createClient({ url: process.env.REDIS_URL }).on("error", (error) => console.error("redis:", error.message));
await redis.connect();

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

async function page() {
  const visits = await redis.incr("visits");
  const notes = await sql`select body, created_at from notes order by id`;
  const items = notes.map((n) => `<li>${escape(n.body)} <small>${n.created_at.toISOString()}</small></li>`).join("");
  return `<!doctype html>
<meta charset="utf-8">
<title>napbox demo</title>
<style>body{font:16px system-ui;max-width:40em;margin:3em auto}small{color:#888}</style>
<h1>napbox demo</h1>
<p>This environment: <code>${escape(process.env.PUBLIC_ADDRESS)}</code> · visits: ${visits}</p>
<form method="post" action="/notes"><input name="body" autofocus required> <button>Add note</button></form>
<ul>${items}</ul>`;
}

async function readForm(req) {
  let body = "";
  for await (const chunk of req) body += chunk;
  return new URLSearchParams(body);
}

http
  .createServer(async (req, res) => {
    try {
      if (req.method === "POST" && req.url === "/notes") {
        const body = (await readForm(req)).get("body")?.trim();
        if (body) await sql`insert into notes (body) values (${body})`;
        res.writeHead(303, { location: "/" }).end();
      } else if (req.method === "GET" && req.url === "/") {
        // 先拿到页面再写响应头：查询出错时下面的 catch 还能回 500
        const html = await page();
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(html);
      } else {
        res.writeHead(404).end("not found");
      }
    } catch (error) {
      console.error(error);
      res.writeHead(500).end("internal error");
    }
  })
  .listen(3000, () => console.log("listening on 3000"));
