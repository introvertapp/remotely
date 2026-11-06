# Third-party source dependencies

`remotely` uses the following Swift source packages at build time. They are compiled into the application; the user does not install separate runtimes.

## itsytv-core

- Project: https://github.com/nickustinov/itsytv-core
- Pinned revision: `052d9a9a0416d577119316ea813aa3b822b408e5`
- License: MIT

Used only as the Apple TV protocol engine behind this project's `AppleTVService` abstraction. The application shell, menu behavior, Preferences UI, remote UI, and product behavior are this project's implementation.

## SwiftProtobuf

- Project: https://github.com/apple/swift-protobuf
- Version: `1.31.0`
- License: Apache License 2.0

The build uses only the SwiftProtobuf runtime library source. Its optional `protoc` binary artifact, generator executable, and build plugin are deliberately excluded because generated protobuf Swift sources are already present in the protocol engine.

## Swift-SRP

- Project: https://github.com/adam-fowler/swift-srp
- Version: `2.4.0`, pinned in `Package.resolved`
- License: Apache License 2.0

## BigNum and its vendored BoringSSL code

- Project: https://github.com/adam-fowler/big-num
- Version: `2.0.3`, pinned in `Package.resolved`
- BigNum license: MIT. Its BoringSSL source retains additional original Google,
  OpenSSL, Eric Young, and other copyright/license notices in the bundled files.

This product includes software developed by the OpenSSL Project for use in the
OpenSSL Toolkit (http://www.openssl.org/). This product includes cryptographic
software written by Eric Young (eay@cryptsoft.com) and software written by Tim
Hudson (tjh@cryptsoft.com).

## SwiftCrypto and SwiftASN1

- Projects: https://github.com/apple/swift-crypto and https://github.com/apple/swift-asn1
- Locked versions: SwiftCrypto `4.5.2`, SwiftASN1 `1.7.3`
- License: Apache License 2.0

These are transitive source dependencies. SwiftCrypto uses the system CryptoKit
implementation on macOS; some dependency targets are only used on other platforms.

## Included files and local modifications

The full bundled license texts and notices are in `Resources/ThirdParty/` in the
repository and `Contents/Resources/ThirdParty/` inside the application. Dependency
privacy resources are also retained in the app. Itsytv-core declares MIT in its
pinned README; the bundled MIT text carries its stated 2026 Nick Ustinov copyright.

The build changes itsytv-core's runtime identity and dependency manifest and
applies the nine patches under `Patches/`. SwiftProtobuf's package manifest is
replaced with a runtime-only manifest. These changes are maintained by remotely.
