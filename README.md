# PalmhelmKit

PalmhelmKit is the Swift package shared by the Palmhelm client apps. It holds the Bridge API client, data models, server-sent-event parsing, endpoint selection and certificate pinning, the shared display rules, and a small set of SwiftUI components. The core does not depend on a UI framework; the `UI/` directory does.

PalmhelmKit is the client side only. The Palmhelm Bridge that it talks to is a separate, proprietary binary and is not part of this repository.

## Requirements

- Swift tools 6.0 (`swift-tools-version: 6.0`), Swift 6 language mode.
- iOS 17 or later, macOS 14 or later.
- Verified with Swift 6.4.2 (Xcode toolchain). Other versions are not verified.

## Use it from Swift Package Manager

```swift
.package(url: "https://github.com/forsakesoul/palmhelm-kit.git", exact: "0.0.1")
```

Then add the `PalmhelmKit` product to your target.

## Build and test

```sh
swift build
swift test
```

`PinningTransportTests` starts `Tests/PalmhelmKitTests/Support/tls-fixture.mjs` as a node child process bound to loopback. The test certificate is generated with `openssl` in a temporary directory and is never committed or stored in the keychain. Running that test needs `node` and `openssl` on your PATH.

## Bridge protocol

Protocol constants and paths live in `Sources/PalmhelmKit/Constants.swift`. The Bridge protocol document is not published yet, so the constants are the reference for now.

- Protocol version `local-api/1` (`BridgeAPI.protocolVersion`). Default port `47821` (`BridgeAPI.defaultPort`).
- Transport: when TLS is enabled, all listen addresses use https with a self-signed certificate that the client pins by SPKI fingerprint (`Pinning.swift`). Plain http is accepted only for loopback (`BridgeClient.allowsPlaintext`).
- Authentication: a device token is sent as a Bearer credential. The pinning delegate refuses HTTP redirects (`Pinning.swift`), so pairing codes and tokens are not forwarded to other addresses.
- Permissions: a read-only device that sends a write request receives `read_only` (`ErrorCode.readOnly`).
- Deadlines are absolute and do not rely on `URLRequest.timeoutInterval` (`BridgeAPI.Deadline`).
- A send whose outcome is uncertain has the state `unknown` (`CommandState`).
- When an event stream falls outside the Bridge's window, the Bridge sends `reset_required` and the client refetches state. Reconnects use backoff (`ReconnectPolicy.swift`).

## Compatibility

- New fields are optional and advisory. A missing or unknown value is handled with the previous behaviour.
- A new client talking to an older Bridge treats missing optional fields as before. An older client talking to a newer Bridge ignores unknown `reason` values and new fields.
- The protocol version stays `local-api/1`. Compatibility currently relies on optional fields and tolerance of unknown values, not on version branching.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security issue, see [SECURITY.md](SECURITY.md); do not open a public issue for it.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

Copyright 2026 forsakesoul

The Palmhelm name and icons are not licensed under Apache-2.0 and are not covered by this license.

---

# PalmhelmKit（中文）

PalmhelmKit 是 Palmhelm 客户端共用的 Swift 包：Bridge API 客户端、数据模型、SSE 解析、端点选择与证书指纹固定、共享的展示规则，以及少量 SwiftUI 组件。核心层不依赖 UI 框架，`UI/` 目录依赖。

本包只是客户端。它所连接的 Palmhelm Bridge 是独立的专有二进制，不在本仓库中。

- 工具链：Swift tools 6.0；iOS 17 与 macOS 14 或更高版本。已在 Swift 6.4.2 上验证。
- 添加依赖：`.package(url: "https://github.com/forsakesoul/palmhelm-kit.git", exact: "0.0.1")`
- 测试：`swift test`。TLS 用例需要本机有 node 与 openssl。
- 协议常量见 `Sources/PalmhelmKit/Constants.swift`。协议文档尚未公开。
- 许可：Apache-2.0，见 [LICENSE](LICENSE)。Copyright 2026 forsakesoul。Palmhelm 名称与图标不在许可范围内。
