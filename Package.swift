// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Audio2Txt",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Audio2TxtApp", targets: ["Audio2TxtApp"])
    ],
    targets: [
        .target(
            name: "Audio2TxtCore",
            path: "Sources/Audio2TxtCore"
        ),
        .executableTarget(
            name: "Audio2TxtApp",
            dependencies: ["Audio2TxtCore"],
            path: "Sources/Audio2TxtApp"
        ),
        .testTarget(
            name: "Audio2TxtTests",
            dependencies: ["Audio2TxtCore"],
            path: "Tests/Audio2TxtTests"
        )
    ]
)
