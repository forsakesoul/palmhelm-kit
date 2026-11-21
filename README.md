# PalmhelmKit

English | [中文](README.zh-CN.md)

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
