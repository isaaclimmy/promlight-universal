// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PromLightUniversal",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PromLightCore", targets: ["PromLightCore"]),
        .executable(name: "PromLight", targets: ["PromLight"]),
    ],
    targets: [
        .target(
            name: "PromLightCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "PromLight",
            dependencies: ["PromLightCore"]
        ),
        .testTarget(
            name: "PromLightCoreTests",
            dependencies: ["PromLightCore"]
        ),
    ]
)
