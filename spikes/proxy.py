# 原型：宿主机端口代理。连接进来时容器若已停止就先启动，等服务端口可连后再转发。
# 用法：python3 proxy.py <监听端口> <容器名> <容器端口>
import asyncio, subprocess, sys, json, time

listen_port, name, target_port = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
waking = None

def container_ip():
    out = subprocess.run(["container", "ls", "--format", "json"], capture_output=True, text=True).stdout
    for c in json.loads(out or "[]"):
        if c["id"] == name and c["status"]["state"] == "running":
            return c["status"]["networks"][0]["ipv4Address"].split("/")[0]
    return None

async def wake():
    ip = container_ip()
    if ip:
        return ip
    started = time.time()
    await asyncio.to_thread(subprocess.run, ["container", "start", name], capture_output=True)
    while True:
        ip = container_ip()
        if ip:
            try:
                r, w = await asyncio.open_connection(ip, target_port)
                w.close()
                print(f"woke {name} in {time.time() - started:.1f}s", flush=True)
                return ip
            except OSError:
                pass
        await asyncio.sleep(0.1)

async def pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
    finally:
        w.close()

async def handle(cr, cw):
    global waking
    if waking is None or waking.done():
        waking = asyncio.ensure_future(wake())
    ip = await asyncio.shield(waking)
    sr, sw = await asyncio.open_connection(ip, target_port)
    await asyncio.gather(pipe(cr, sw), pipe(sr, cw), return_exceptions=True)

async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", listen_port)
    print("listening", listen_port, flush=True)
    await server.serve_forever()

asyncio.run(main())
