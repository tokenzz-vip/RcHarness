// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RcHarness",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RcHarness", targets: ["RcHarness"]),
    ],
    targets: [
        .target(name: "AudioExceptionGuard", path: "Sources/AudioExceptionGuard",
                publicHeadersPath: "include", linkerSettings: [.linkedFramework("AVFoundation")]),
        .executableTarget(
            name: "RcHarness",
            dependencies: ["AudioExceptionGuard"],
            path: "Sources/RcHarness",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "RcHarnessTests",
            dependencies: ["RcHarness"],
            path: "tests/RcHarnessTests"
        ),
    ]
)
