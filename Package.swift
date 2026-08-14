// swift-tools-version: 5.10
import PackageDescription

// The build script prepares the protocol engine as a local source checkout in
// Vendor/ before SwiftPM resolves this package. Keeping it local lets us patch
// its SwiftProtobuf dependency to the runtime-only source package and avoids
// SwiftProtobuf's optional protoc binary artifact entirely.
let package = Package(
    name: "remotely",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(name: "ProtocolCore", path: "Vendor/ProtocolCore")
    ],
    targets: [
        .executableTarget(
            name: "remotely",
            dependencies: [
                .product(name: "ItsytvCore", package: "ProtocolCore")
            ],
            path: "Sources/remotely"
        )
    ]
)
