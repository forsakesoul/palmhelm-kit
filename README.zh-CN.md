# PalmhelmKit

[English](README.md) | 中文

PalmhelmKit 是 Palmhelm 客户端共用的 Swift 包。它包含 Bridge API 客户端、数据模型、server-sent-event（SSE）解析、端点选择与证书指纹固定、共享的展示规则，以及少量 SwiftUI 组件。核心层不依赖 UI 框架，`UI/` 目录依赖。

本包只包含客户端。它连接的 Palmhelm Bridge 是独立的专有二进制，不在本仓库中。

## 要求

- Swift tools 6.0（`swift-tools-version: 6.0`），Swift 6 语言模式。
- iOS 17 或更高版本，macOS 14 或更高版本。
- 已在 Swift 6.4.2（Xcode 工具链）上验证。其它版本未验证。

## 通过 Swift Package Manager 使用

```swift
.package(url: "https://github.com/forsakesoul/palmhelm-kit.git", exact: "0.0.4")
```

然后把 `PalmhelmKit` 产品加入你的 target。

## 构建与测试

```sh
swift build
swift test
```

`PinningTransportTests` 会把 `Tests/PalmhelmKitTests/Support/tls-fixture.mjs` 作为绑定到回环地址的 node 子进程启动。测试证书由 `openssl` 在临时目录中生成，从不提交，也不存入钥匙串。运行该测试需要 `node` 与 `openssl` 位于你的 PATH 中。

## Bridge 协议

协议常量与路径位于 `Sources/PalmhelmKit/Constants.swift`。Bridge 客户端协议见 [docs/PROTOCOL.zh-CN.md](docs/PROTOCOL.zh-CN.md)（English: [docs/PROTOCOL.md](docs/PROTOCOL.md)）；常量仍是代码层面的参照。

- 协议版本 `local-api/1`（`BridgeAPI.protocolVersion`）。默认端口 `47821`（`BridgeAPI.defaultPort`）。
- 传输：启用 TLS 时，所有监听地址使用 https，证书为自签名，客户端按 SPKI 指纹固定（`Pinning.swift`）。明文 http 仅允许回环地址（`BridgeClient.allowsPlaintext`）。
- 鉴权：设备令牌以 Bearer 凭据发送。固定（pinning）代理拒绝 HTTP 重定向（`Pinning.swift`），因此配对码与令牌不会被转发到其它地址。
- 权限：只读设备发送写请求时，会收到 `read_only`（`ErrorCode.readOnly`）。
- 截止时间是绝对的，不依赖 `URLRequest.timeoutInterval`（`BridgeAPI.Deadline`）。
- 结果不确定的发送，状态为 `unknown`（`CommandState`）。
- 当事件流超出 Bridge 的窗口时，Bridge 发送 `reset_required`，客户端重新获取状态。重连使用退避策略（`ReconnectPolicy.swift`）。

## 兼容性

- 新字段是可选的、仅作提示用途。缺失或未知的值按之前的行为处理。
- 新客户端连接旧 Bridge 时，缺失的可选字段按之前的方式处理。旧客户端连接新 Bridge 时，忽略未知的 `reason` 值和新字段。
- 协议版本保持为 `local-api/1`。目前的兼容性依赖可选字段和对未知值的容忍，而不是版本分支。

## 贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.md)。如需报告安全问题，参见 [SECURITY.md](SECURITY.md)；请勿为此开公开 issue。

## 许可

以 Apache License, Version 2.0 授权。参见 [LICENSE](LICENSE)。

Copyright 2026 forsakesoul

Palmhelm 名称与图标未以 Apache-2.0 授权，不在本许可范围内。
