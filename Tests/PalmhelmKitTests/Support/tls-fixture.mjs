// 测试专用本地端点（只在 swift test 里由 PinningTransportTests 以子进程启动，只绑 127.0.0.1，证书在任务临时目录）。
// 用途：用真实 URLSession + 真实 BridgeClient 验证固定证书、重定向、明文端点等传输行为（A1-060 P0-2）。
//
// 配置从 argv[2] 读 JSON：{ servers: [{ name, cert?, key?, redirect?: { status, to?, scheme?, path? } }], spki }。
//   redirect.to   另一个服务名：Location 在请求时按它的实际端口拼出（所有服务同进程启动，端口都有效）
//   redirect.path 同源新路径：Location 指向本服务自己的该路径（落地路径正常应答，用于抓“只跟随同源”）
//
// 观察（只计数，不保存内容）：
//   bytes[name]  TLS 解密后（或明文端点）收到的应用层字节数——请求头一到就会计入，不等请求体收完
//   reqs         handler 入口即记录：服务、路径、是否带 Authorization；请求体结束时补 code 字段是否出现、是否中途断开
//   open[name]   当前未关闭的 TCP 连接数（含握手未完成/失败的原始连接）；GET /obs?settle=<ms> 等这些连接都关闭再返回，
//                返回体带 settled：到期仍有未关闭连接时 settled=false，测试必须拒绝这份快照
// 控制口（明文 http）：GET /obs、GET /swap?name=&cert=&key=（换证书并断开现有连接）。
//
// 自测：argv[2] 为 --selftest <cert> <key> 时，起一个端点并用 TLS 客户端只发请求头 + 半截请求体后断开，
// 校验字节与请求头计数都已记录（证明“零请求”断言看的是到达即计数的观察器），成功 exit 0。
import https from "node:https";
import http from "node:http";
import tls from "node:tls";
import fs from "node:fs";

const obs = { reqs: [], bytes: {}, open: {} };
const servers = {};
const ports = {};

// 所有应答都带 Connection: close：客户端的长连接不会把排空屏障一直拖住
const json = (res, status, body) => {
  res.writeHead(status, { "Content-Type": "application/json", Connection: "close" });
  res.end(JSON.stringify(body));
};

const handler = (name, redirect, spki) => (req, res) => {
  const r = { server: name, path: req.url, auth: !!req.headers.authorization, code: false, aborted: false };
  obs.reqs.push(r); // 请求头到达即记录
  let body = "";
  req.on("data", (c) => {
    body += c;
    if (/"code"/.test(body)) r.code = true;
  });
  req.on("aborted", () => (r.aborted = true));
  req.on("end", () => {
    if (redirect && req.url !== redirect.path) {
      const loc = redirect.path ? `${req.socket.encrypted ? "https" : "http"}://127.0.0.1:${ports[name]}${redirect.path}` : `${redirect.scheme}://127.0.0.1:${ports[redirect.to]}/v1/health`;
      res.writeHead(redirect.status, { Location: loc, Connection: "close" });
      return res.end();
    }
    if (req.url.startsWith("/v1/health") || (redirect && req.url === redirect.path)) return json(res, 200, { ok: true, protocol: "local-api/1" });
    if (req.url.startsWith("/pair")) return json(res, 200, { deviceId: "d-test", token: "t-test", spkiSha256: spki });
    if (req.url.startsWith("/v1/events")) {
      res.writeHead(200, { "Content-Type": "text/event-stream", Connection: "close" });
      res.write('event: ready\ndata: {"highWater":0}\n\n');
      setTimeout(() => res.end(), 150);
      return;
    }
    json(res, 404, { error: "not_found" });
  });
};

const watch = (name, srv, tlsServer) => {
  obs.bytes[name] = 0;
  obs.open[name] = 0;
  // 连接生命周期：在原始 TCP 连接上登记（握手失败的也算），关闭时减掉
  srv.on("connection", (raw) => {
    obs.open[name] += 1;
    raw.once("close", () => (obs.open[name] -= 1));
    if (!tlsServer) raw.on("data", (d) => (obs.bytes[name] += d.length)); // 明文端点：连接上的字节就是应用层字节
  });
  // TLS 端点：只在解密后的 TLSSocket 上累加应用层字节（ClientHello 等握手字节不算）
  if (tlsServer) srv.on("secureConnection", (sock) => sock.on("data", (d) => (obs.bytes[name] += d.length)));
};

const listen = (srv) => new Promise((ok) => srv.listen(0, "127.0.0.1", () => ok(srv.address().port)));

async function selftest(cert, key) {
  const srv = https.createServer({ cert: fs.readFileSync(cert), key: fs.readFileSync(key) }, handler("T", null, ""));
  watch("T", srv, true);
  const port = await listen(srv);
  await new Promise((ok, fail) => {
    const s = tls.connect({ host: "127.0.0.1", port, rejectUnauthorized: false }, () => {
      s.write('POST /pair HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer synthetic\r\nContent-Type: application/json\r\nContent-Length: 400\r\n\r\n{"code":"12');
      setTimeout(() => { s.destroy(); ok(); }, 200);
    });
    s.on("error", fail);
  });
  await new Promise((ok) => setTimeout(ok, 200));
  const r = obs.reqs[0];
  const pass = obs.bytes.T > 0 && obs.reqs.length === 1 && r.auth && r.code && obs.open.T === 0;
  process.stdout.write(JSON.stringify({ pass, bytes: obs.bytes.T, reqs: obs.reqs.length, auth: r?.auth, code: r?.code, aborted: r?.aborted }) + "\n");
  process.exit(pass ? 0 : 1);
}

if (process.argv[2] === "--selftest") {
  await selftest(process.argv[3], process.argv[4]);
} else {
  const cfg = JSON.parse(process.argv[2]);
  for (const s of cfg.servers) {
    const h = handler(s.name, s.redirect, cfg.spki);
    const srv = s.cert ? https.createServer({ cert: fs.readFileSync(s.cert), key: fs.readFileSync(s.key) }, h) : http.createServer(h);
    srv.on("clientError", (_e, sock) => sock.destroy());
    srv.on("tlsClientError", () => {});
    watch(s.name, srv, !!s.cert);
    servers[s.name] = srv;
    ports[s.name] = await listen(srv);
  }
  const ctl = http.createServer(async (req, res) => {
    const u = new URL(req.url, "http://127.0.0.1");
    if (u.pathname === "/obs") {
      const deadline = Date.now() + Number(u.searchParams.get("settle") ?? 0);
      const busy = () => Object.values(obs.open).some((n) => n > 0);
      while (Date.now() < deadline && busy()) await new Promise((ok) => setTimeout(ok, 20));
      return json(res, 200, { ...obs, settled: !busy() });
    }
    if (u.pathname === "/swap") {
      const srv = servers[u.searchParams.get("name")];
      srv.setSecureContext({ cert: fs.readFileSync(u.searchParams.get("cert")), key: fs.readFileSync(u.searchParams.get("key")) });
      srv.closeAllConnections();
      return json(res, 200, { ok: true });
    }
    json(res, 404, {});
  });
  ports.ctl = await listen(ctl);
  process.stdout.write(JSON.stringify(ports) + "\n");
  process.stdin.on("end", () => process.exit(0)); // 测试关掉 stdin 即退出
  process.stdin.resume();
}
