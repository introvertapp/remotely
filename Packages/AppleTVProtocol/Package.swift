// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppleTVProtocol",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ItsytvCore", targets: ["ItsytvCore"])],
    dependencies: [
        .package(path: "../SwiftProtobuf"),
        .package(url: "https://github.com/adam-fowler/swift-srp.git", exact: "2.4.0")
    ],
    targets: [
        .target(
            name: "ItsytvCore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "SwiftProtobuf"),
                .product(name: "SRP", package: "swift-srp")
            ]
        )
    ]
)
