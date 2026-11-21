#if os(macOS)
import XCTest
import CryptoKit
@testable import PalmhelmKit

// A1-060 P0-2：真实 URLSession + 真实 BridgeClient（默认生产会话构造）对本地 TLS 端点的传输行为。
// 端点是 Support/tls-fixture.mjs（node 子进程，只绑回环）；证书由 openssl 在任务临时目录生成，不入库、不进钥匙串。
//
// 断言口径：
// - “零请求”= 目标端点的应用层字节数与 handler 记录都不变（观察器在请求头到达时就计数，见夹具自测），
//   且在客户端调用结束、相关连接全部关闭（/obs?settle）之后再取；每组都有正确 pin 的正控证明端点可达。
// - 只有 node/openssl 确实不存在才跳过；工具存在后的任何失败都是测试失败，不会变成“跳过”。
// - 每个子进程、网络调用、收尾都有总期限；收尾 TERM → 有界等待 → KILL，并确认退出。
final class PinningTransportTests: XCTestCase {
    struct Cert { let pem: String; let key: String; let spki: String }
    struct Req: Decodable { let server: String; let path: String; let auth: Bool; let code: Bool; let aborted: Bool }
    struct Snapshot: Decodable { let reqs: [Req]; let bytes: [String: Int]; let open: [String: Int]; let settled: Bool }
    /// 后台读取结果的容器（跨线程只经锁访问）。
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var v: T
        init(_ v: T) { self.v = v }
        func set(_ n: T) { lock.withLock { v = n } }
        func get() -> T { lock.withLock { v } }
    }
    struct FixtureError: Error, CustomStringConvertible { let description: String }

    private var dir: URL!
    private var node = "", openssl = ""
    private var fixture: Process?
    private var stdinPipe: Pipe?
    private var ports: [String: Int] = [:]

    override func setUpWithError() throws {
        // 依赖预检：只有这里能跳过
        guard let n = Self.which("node") else { throw XCTSkip("node 不在 PATH") }
        guard let o = Self.which("openssl") else { throw XCTSkip("openssl 不在 PATH") }
        node = n; openssl = o
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("palmhelm-test-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        stopFixture()
        if let dir { XCTAssertNoThrow(try FileManager.default.removeItem(at: dir), "任务证书目录应能删除") }
    }

    private static func which(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [tool]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }

    // ---- 子进程：有界执行与收尾 ----

    /// 运行工具到结束：stdout 读完与进程退出共用一个绝对期限 seconds；到期仍在运行就回收并失败。
    /// 只有确认进程已退出才读 terminationStatus（运行中读会抛 ObjC 异常）。stderr 丢弃。
    @discardableResult
    private func run(_ exe: String, _ args: [String], seconds: Double = 10, allowFailure: Bool = false) throws -> Data {
        let deadline = Date().addingTimeInterval(seconds)
        let name = (exe as NSString).lastPathComponent
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { Self.reap(p) } } // 任何异常路径都不留子进程
        let data = Box(Data())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "palmhelm.test.read").async { data.set(out.fileHandleForReading.readDataToEndOfFile()); done.signal() }
        if done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
            Self.reap(p); throw FixtureError(description: "\(name) 超时（\(seconds)s，stdout 未结束）")
        }
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { Self.reap(p); throw FixtureError(description: "\(name) 超时（\(seconds)s，stdout 已关但进程未退出）") }
        guard allowFailure || p.terminationStatus == 0 else { throw FixtureError(description: "\(name) 退出码 \(p.terminationStatus)") }
        return data.get()
    }

    /// TERM → 最多等 3 秒 → KILL → 再最多等 2 秒。只作用于本测试启动的进程。
    /// 不用 waitUntilExit：它在主线程上会跑 runloop 等通知，进程已被回收时可能永远不返回（实测卡住 tearDown）。
    private static func reap(_ p: Process) {
        func wait(_ s: Double) { let d = Date().addingTimeInterval(s); while p.isRunning && Date() < d { usleep(20_000) } }
        wait(0.5) // 关掉 stdin 后夹具会自己退出
        guard p.isRunning else { return }
        p.terminate(); wait(3)
        if p.isRunning { kill(p.processIdentifier, SIGKILL); wait(2) }
    }

    private func stopFixture() {
        try? stdinPipe?.fileHandleForWriting.close()
        if let p = fixture { Self.reap(p); XCTAssertFalse(p.isRunning, "夹具进程应已退出") }
        fixture = nil; stdinPipe = nil
    }

    // ---- 证书 ----

    private func key(_ name: String) throws -> String {
        let k = dir.appendingPathComponent("\(name).key").path
        try run(openssl, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", k])
        return k
    }

    private func cert(key k: String, cn: String) throws -> Cert {
        let pem = dir.appendingPathComponent("\(cn).pem").path
        try run(openssl, ["req", "-new", "-x509", "-key", k, "-subj", "/CN=\(cn)", "-days", "2", "-addext", "subjectAltName=IP:127.0.0.1", "-out", pem])
        let der = try run(openssl, ["pkey", "-in", k, "-pubout", "-outform", "DER"])
        return Cert(pem: pem, key: k, spki: Data(SHA256.hash(data: der)).base64EncodedString())
    }

    // ---- 夹具 ----

    private var script: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/tls-fixture.mjs").path }

    private func start(_ servers: [[String: Any]], spki: String) throws {
        stopFixture()
        let cfg = try JSONSerialization.data(withJSONObject: ["servers": servers, "spki": spki])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script, String(decoding: cfg, as: UTF8.self)]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardInput = inp; p.standardError = FileHandle.nullDevice
        try p.run()
        fixture = p; stdinPipe = inp
        // 启动行：总期限 10 秒、最长 4 KB；提前 EOF / 非法 JSON 都是失败
        let result = Box((line: Data(), eof: false))
        let done = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        DispatchQueue(label: "palmhelm.test.ready").async {
            var line = Data(), eof = false
            while line.count < 4096 {
                let b = handle.readData(ofLength: 1)
                if b.isEmpty { eof = true; break }
                if b == Data("\n".utf8) { break }
                line.append(b)
            }
            result.set((line, eof))
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut { stopFixture(); throw FixtureError(description: "夹具 10 秒内未就绪") }
        let (line, eof) = result.get()
        if eof { stopFixture(); throw FixtureError(description: "夹具在就绪前退出") }
        guard let parsed = try? JSONDecoder().decode([String: Int].self, from: line), parsed["ctl"] != nil else {
            stopFixture(); throw FixtureError(description: "夹具就绪行不是合法端口表")
        }
        ports = parsed
    }

    private func control(_ path: String) async throws -> Data {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(ports["ctl"]!)\(path)")!)
        r.timeoutInterval = 5
        return try await URLSession(configuration: .ephemeral).data(for: r).0
    }

    /// 排空屏障：等所有连接（含握手失败的原始连接）关闭后取观察表；到期仍未排空就失败，不拿未排空的快照做零断言。
    private func snapshot() async throws -> Snapshot {
        let s = try JSONDecoder().decode(Snapshot.self, from: try await control("/obs?settle=3000"))
        guard s.settled else { throw FixtureError(description: "观察未排空：仍有未关闭连接 \(s.open.filter { $0.value > 0 })") }
        return s
    }

    private func httpClient(_ server: String, token: String? = nil) -> BridgeClient {
        BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: ports[server]!, transport: .http), token: token)
    }

    private func client(_ server: String, pin: String?, token: String? = nil) -> BridgeClient {
        BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: ports[server]!, transport: .https, spkiSha256: pin), token: token)
    }

    /// 单个网络调用的总期限（默认 8 秒）：超时取消并作为失败。
    private static func bounded<T: Sendable>(seconds: Double = 8, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: .seconds(seconds)); throw FixtureError(description: "网络调用超过 \(seconds)s") }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    /// 拉完事件流（有总期限），返回收到的事件。
    private static func drain(_ c: BridgeClient) async throws -> [BridgeEvent] {
        try await bounded {
            var got: [BridgeEvent] = []
            for try await e in try await c.events(since: nil) { got.append(e) }
            return got
        }
    }

    /// 期望抛错的调用：超时不算“抛错”，而是测试失败。
    private func expectRejected<T: Sendable>(_ what: String, _ op: @escaping @Sendable () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await Self.bounded(op)
            XCTFail("\(what)：应被拒绝却成功", file: file, line: line)
        } catch let e as FixtureError {
            XCTFail("\(what)：\(e.description)", file: file, line: line)
        } catch {}
    }

    // ---- 观察器自测：半截请求后断开，字节与认证头也已计数 ----

    func testObserverCountsPartialRequest() throws {
        let a = try cert(key: try key("a"), cn: "palmhelm-test-a")
        let out = try run(node, [script, "--selftest", a.pem, a.key])
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("\"pass\":true"), String(decoding: out, as: UTF8.self))
    }

    // ---- 排空屏障自测：握手未完成的原始连接也计入；未关闭时拿不到快照，关闭后才能拿到 ----

    func testBarrierRejectsUndrainedConnection() async throws {
        let a = try cert(key: try key("a"), cn: "palmhelm-test-a")
        try start([["name": "S", "cert": a.pem, "key": a.key]], spki: a.spki)
        // 原始 TCP 连接，不发任何 TLS 字节（握手未完成）
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(UInt16(ports["S"]!).bigEndian); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        do {
            _ = try await snapshot()
            XCTFail("连接未关闭时不应拿到排空快照")
        } catch let e as FixtureError { XCTAssertTrue(e.description.contains("未排空"), e.description) }
        close(fd)
        let s = try await snapshot()
        XCTAssertEqual(s.open["S"], 0)
        XCTAssertEqual(s.bytes["S"], 0, "握手未完成：没有应用层字节")
    }

    // ---- 工具 stdout 关闭后仍不退出：按期限回收并失败，不留子进程、不抛 ObjC 异常 ----

    func testToolThatClosesStdoutButHangsIsReaped() throws {
        let marker = "palmhelm-test-hang-\(UUID().uuidString.prefix(8))"
        XCTAssertThrowsError(try run(node, ["-e", "require('fs').closeSync(1);setInterval(()=>{},1000)", marker], seconds: 1)) { e in
            XCTAssertTrue("\(e)".contains("进程未退出"), "\(e)")
        }
        let left = try run("/usr/bin/pgrep", ["-f", marker], seconds: 3, allowFailure: true)
        XCTAssertTrue(left.isEmpty, "挂住的子进程应已被回收")
    }

    // ---- P0-2-01：pin 不符 / 缺失 / 只有末字节不同 → 三个入口都零应用层字节 ----

    func testWrongMissingAndPrefixPinSendNothing() async throws {
        let a = try cert(key: try key("a"), cn: "palmhelm-test-a")
        let b = try cert(key: try key("b"), cn: "palmhelm-test-b")
        try start([["name": "S", "cert": a.pem, "key": a.key]], spki: a.spki)

        // 正控：正确 pin 三个入口都能到达（证明端点可达、事件流走任务级挑战）
        let ok = client("S", pin: a.spki, token: "t")
        _ = try await Self.bounded { try await ok.health() }
        let okPair = client("S", pin: a.spki)
        _ = try await Self.bounded { try await okPair.pair(code: "123456", deviceName: "test") }
        let events = try await Self.drain(client("S", pin: a.spki, token: "t"))
        XCTAssertTrue(events.contains(.ready(highWater: 0)), "正确 pin 下事件流应收到 ready")
        let control = try await snapshot()
        XCTAssertEqual(control.reqs.count, 3)
        XCTAssertGreaterThan(control.bytes["S"] ?? 0, 0)

        var raw = Data(base64Encoded: a.spki)!; raw[31] ^= 0xFF // 前 31 字节相同：网络认证必须比完整摘要
        for pin in [b.spki, "", raw.base64EncodedString()] {
            let c1 = client("S", pin: pin, token: "t"), c2 = client("S", pin: pin), c3 = client("S", pin: pin, token: "t")
            await expectRejected("health pin=\(pin.prefix(6))") { try await c1.health() }
            await expectRejected("pair pin=\(pin.prefix(6))") { try await c2.pair(code: "123456", deviceName: "test") }
            await expectRejected("events pin=\(pin.prefix(6))") { try await Self.drain(c3) }
        }
        let after = try await snapshot()
        XCTAssertEqual(after.reqs.count, control.reqs.count, "pin 不符：服务端不应出现新的请求头")
        XCTAssertEqual(after.bytes["S"], control.bytes["S"], "pin 不符：服务端不应收到任何应用层字节")
    }

    // ---- P0-2-02：换钥拒绝、同公钥续签放行 ----

    func testKeySwapRejectedSameKeyReissueAccepted() async throws {
        let ka = try key("a")
        let a = try cert(key: ka, cn: "palmhelm-test-a")
        let a2 = try cert(key: ka, cn: "palmhelm-test-a2") // 同一私钥重新签发：SPKI 不变
        let b = try cert(key: try key("b"), cn: "palmhelm-test-b")
        XCTAssertEqual(a.spki, a2.spki)
        try start([["name": "S", "cert": a.pem, "key": a.key]], spki: a.spki)
        let c0 = client("S", pin: a.spki, token: "t")
        _ = try await Self.bounded { try await c0.health() }

        _ = try await control("/swap?name=S&cert=\(b.pem)&key=\(b.key)") // 同时断开旧连接，强制新握手
        let before = try await snapshot()
        let c1 = client("S", pin: a.spki, token: "t"), c2 = client("S", pin: a.spki, token: "t")
        await expectRejected("换钥后 health") { try await c1.health() }
        await expectRejected("换钥后 events") { try await Self.drain(c2) }
        let afterSwap = try await snapshot()
        XCTAssertEqual(afterSwap.reqs.count, before.reqs.count, "换钥后不应出现新的请求头")
        XCTAssertEqual(afterSwap.bytes["S"], before.bytes["S"], "换钥后不应向新证书发送任何应用层字节")

        _ = try await control("/swap?name=S&cert=\(a2.pem)&key=\(a2.key)")
        let c3 = client("S", pin: a.spki, token: "t")
        _ = try await Self.bounded { try await c3.health() } // 固定的是公钥摘要，不是整张证书
    }

    // ---- P0-2-03：3xx 一律不跟随（跨端点与同源新路径），目的端零字节 ----

    func testRedirectsNeverFollowed() async throws {
        let a = try cert(key: try key("a"), cn: "palmhelm-test-a")
        let d = try cert(key: try key("d"), cn: "palmhelm-test-d")
        let statuses = [301, 302, 303, 307, 308]
        let dests: [(String, String)] = [("DsamePin", "https"), ("Dother", "https"), ("H", "http")]
        var servers: [[String: Any]] = [["name": "DsamePin", "cert": a.pem, "key": a.key], ["name": "Dother", "cert": d.pem, "key": d.key], ["name": "H"]]
        for st in statuses {
            for (to, scheme) in dests { servers.append(["name": "S\(st)\(to)", "cert": a.pem, "key": a.key, "redirect": ["status": st, "to": to, "scheme": scheme]]) }
            servers.append(["name": "S\(st)same", "cert": a.pem, "key": a.key, "redirect": ["status": st, "path": "/landing"]]) // 同源新路径
        }
        try start(servers, spki: a.spki)

        // 正控：同 pin 目的端可直连；同源落地路径可直连（证明“零次”不是因为不可达）
        let direct = client("DsamePin", pin: a.spki, token: "t")
        _ = try await Self.bounded { try await direct.health() }
        let base = try await snapshot()

        for st in statuses {
            for src in dests.map({ "S\(st)\($0.0)" }) + ["S\(st)same"] {
                let c1 = client(src, pin: a.spki, token: "t"), c2 = client(src, pin: a.spki), c3 = client(src, pin: a.spki, token: "t")
                await expectRejected("\(src) health") { try await c1.health() }
                await expectRejected("\(src) pair") { try await c2.pair(code: "123456", deviceName: "test") }
                await expectRejected("\(src) events") { try await Self.drain(c3) }
            }
        }
        let obs = try await snapshot()
        let sources = obs.reqs.filter { $0.server.hasPrefix("S") }
        XCTAssertEqual(sources.filter { $0.path != "/landing" }.count, statuses.count * (dests.count + 1) * 3, "源端只收到本次请求")
        XCTAssertEqual(sources.filter { $0.path == "/landing" }.count, 0, "同源新路径的重定向也不应跟随")
        for (to, _) in dests {
            XCTAssertEqual(obs.bytes[to], base.bytes[to], "\(to)：目的端不应收到任何应用层字节")
        }
        XCTAssertEqual(obs.reqs.filter { !$0.server.hasPrefix("S") }.count, base.reqs.count, "目的端不应出现新的请求头")
    }

    // A1-080 F1-R：回环明文源端的 3xx 同样不跟随——配对 body（307/308 保留 POST）与 Bearer 不得被转发到别的端点。
    func testHttpRedirectsNeverFollowed() async throws {
        let a = try cert(key: try key("a"), cn: "palmhelm-test-a")
        let statuses = [301, 302, 303, 307, 308]
        let dests: [(String, String)] = [("H", "http"), ("D", "https")]
        var servers: [[String: Any]] = [["name": "H"], ["name": "D", "cert": a.pem, "key": a.key]]
        for st in statuses {
            for (to, scheme) in dests { servers.append(["name": "P\(st)\(to)", "redirect": ["status": st, "to": to, "scheme": scheme]]) }
            servers.append(["name": "P\(st)same", "redirect": ["status": st, "path": "/landing"]])
        }
        try start(servers, spki: a.spki)

        let direct = httpClient("H") // 正控：明文目的端本身可达
        _ = try await Self.bounded { try await direct.health() }
        let base = try await snapshot()

        for st in statuses {
            for src in dests.map({ "P\(st)\($0.0)" }) + ["P\(st)same"] {
                let c1 = httpClient(src, token: "t"), c2 = httpClient(src), c3 = httpClient(src, token: "t")
                await expectRejected("\(src) health") { try await c1.health() }
                await expectRejected("\(src) pair") { try await c2.pair(code: "123456", deviceName: "test") }
                await expectRejected("\(src) events") { try await Self.drain(c3) }
            }
        }
        let obs = try await snapshot()
        let sources = obs.reqs.filter { $0.server.hasPrefix("P") }
        XCTAssertEqual(sources.filter { $0.path != "/landing" }.count, statuses.count * (dests.count + 1) * 3, "源端只收到本次请求")
        XCTAssertEqual(sources.filter { $0.path == "/landing" }.count, 0, "同源新路径的重定向也不应跟随")
        for (to, _) in dests {
            XCTAssertEqual(obs.bytes[to], base.bytes[to], "\(to)：目的端不应收到任何应用层字节")
        }
        XCTAssertEqual(obs.reqs.filter { !$0.server.hasPrefix("P") }.count, base.reqs.count, "目的端不应出现新的请求头")
    }

    // ---- P0-2-04：对明文端点发 https：失败，且明文端点收不到 HTTP 请求 ----

    func testPlainEndpointGetsNoHTTPRequest() async throws {
        let a = try cert(key: try key("a"), cn: "palmhelm-test-a")
        try start([["name": "P"]], spki: a.spki)
        let c1 = client("P", pin: a.spki, token: "t"), c2 = client("P", pin: a.spki), c3 = client("P", pin: a.spki, token: "t")
        await expectRejected("plain health") { try await c1.health() }
        await expectRejected("plain pair") { try await c2.pair(code: "123456", deviceName: "test") }
        await expectRejected("plain events") { try await Self.drain(c3) }
        let obs = try await snapshot()
        XCTAssertEqual(obs.reqs.count, 0, "https 客户端不应回退明文：明文端点只会看到 TLS 握手字节，形成不了 HTTP 请求")
    }
}
#endif
