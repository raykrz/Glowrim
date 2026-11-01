// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glowrim",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Glowrim",
            path: "Sources/Glowrim",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
