// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperDemo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WhisperDemo",
            path: "Sources/WhisperDemo",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"), // kVK_ virtual keycodes
            ]
        )
    ]
)
