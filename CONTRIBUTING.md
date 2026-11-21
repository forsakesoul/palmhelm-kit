# Contributing

## Development and tests

Requirements: Swift tools 6.0 (Swift 6.4.2 verified), iOS 17 / macOS 14 SDKs, and, for the TLS test only, `node` and `openssl` on your PATH.

```sh
swift build
swift test
```

## Protocol compatibility

PalmhelmKit talks to the Palmhelm Bridge, which may be older or newer than this package. Keep changes compatible:

- New fields must be optional, and missing or unknown values must keep the previous behaviour.
- Do not remove or rename existing fields, error codes, or paths in a way that breaks older clients.
- Do not change a meaning silently; document the change in the pull request.

## Licensing of contributions

By submitting a contribution you agree that it is licensed under the Apache License, Version 2.0, as described in Section 5 of [LICENSE](LICENSE).
