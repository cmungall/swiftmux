// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftMux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SwiftMux",
            targets: ["SwiftMux"]
        ),
        .executable(
            name: "SwiftMuxServer",
            targets: ["SwiftMuxServer"]
        ),
        .library(
            name: "SwiftMuxCore",
            targets: ["SwiftMuxCore"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.2.5"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.22.0"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird-websocket.git",
            exact: "2.6.0"
        )
    ],
    targets: [
        .target(
            name: "SwiftMuxCore",
            path: "Sources/SwiftMuxCore"
        ),
        .target(
            name: "CSwiftMuxPTY",
            path: "Sources/CSwiftMuxPTY",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SwiftMux",
            dependencies: [
                "SwiftTerm"
            ],
            path: "Sources/SwiftMux",
            exclude: [
                "Resources"
            ]
        ),
        .executableTarget(
            name: "SwiftMuxServer",
            dependencies: [
                "SwiftMuxCore",
                "CSwiftMuxPTY",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket")
            ],
            path: "Sources/SwiftMuxServer"
        )
    ]
)
