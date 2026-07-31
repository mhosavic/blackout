// swift-tools-version:6.0
import PackageDescription
import Foundation

// Command Line Tools ships Testing.framework, but unlike Xcode, SwiftPM does
// not add its search paths automatically. Wire them up when present so the
// blackout-tests runner builds without a full Xcode install.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingSupport = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

var testSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
var testLinkerSettings: [LinkerSetting] = []
if FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework") {
    testSwiftSettings.append(.unsafeFlags(["-F", cltFrameworks, "-plugin-path", cltTestingPlugins]))
    testLinkerSettings.append(.unsafeFlags([
        "-F", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltTestingSupport
    ]))
}

let package = Package(
    name: "blackout",
    platforms: [
        // Swift Testing's bundled framework requires macOS 14
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "BlackoutCore",
            path: "Sources/BlackoutCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "blackout",
            dependencies: ["BlackoutCore"],
            path: "Sources/blackout",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks", "-framework", "DisplayServices"])
            ]
        ),
        .executableTarget(
            name: "blackout-daemon",
            path: "Sources/blackout-daemon",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "blackout-tests",
            dependencies: ["BlackoutCore"],
            path: "Tests/BlackoutTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
