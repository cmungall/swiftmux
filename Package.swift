// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "SwiftMux",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SwiftMux",
            targets: ["SwiftMux"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.2.5"
        )
    ],
    targets: [
        .executableTarget(
            name: "SwiftMux",
            dependencies: [
                "SwiftTerm"
            ],
            path: "Sources/SwiftMux",
            exclude: [
                "Resources"
            ]
        )
    ]
)
