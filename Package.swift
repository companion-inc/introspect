// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Introspect",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Introspect", targets: ["IntrospectApp"])
    ],
    targets: [
        .executableTarget(
            name: "IntrospectApp",
            path: "Sources/IntrospectApp"
        )
    ]
)
