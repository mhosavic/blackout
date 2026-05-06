// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "blackout",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "blackout",
            path: "Sources/blackout",
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks", "-framework", "DisplayServices"])
            ]
        ),
        .executableTarget(
            name: "blackout-daemon",
            path: "Sources/blackout-daemon",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
