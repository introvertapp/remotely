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
- Version selected by the pinned protocol engine
- License: Apache License 2.0

For redistribution beyond personal use, retain the applicable upstream license and notice files according to each project's license terms.
