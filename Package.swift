// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "UnmountAll",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "UnmountAll", targets: ["UnmountAll"])
    ],
    targets: [
        .executableTarget(
            name: "UnmountAll",
            path: "Sources/UnmountAll"
        )
    ]
)
