// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftProtobuf",
    products: [.library(name: "SwiftProtobuf", targets: ["SwiftProtobuf"])],
    targets: [
        .target(name: "SwiftProtobuf", resources: [.copy("PrivacyInfo.xcprivacy")])
    ]
)
