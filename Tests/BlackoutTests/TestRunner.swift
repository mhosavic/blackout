import Testing

// Runs the swift-testing suite directly: `swift run blackout-tests`.
// Tests are an executable rather than a .testTarget because `swift test`
// cannot execute Swift Testing bundles under Command Line Tools alone
// (no full Xcode). This calls the same entry point SwiftPM's generated
// runner uses, and exits nonzero on any failure.
@main
struct TestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
