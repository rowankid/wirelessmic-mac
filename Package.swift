// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WirelessMic",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "WirelessMic", targets: ["WirelessMic"]),
    ],
    targets: [
        .executableTarget(
            name: "WirelessMic",
            path: "Sources/WirelessMic",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
