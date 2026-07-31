import Testing
import Foundation
import BlackoutCore

struct SleepControllerTests {

    // Real `pmset -g` output shape; the SleepDisabled line is absent unless set
    private let pmsetOutputNormal = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     disksleep            10
     sleep                1 (sleep prevented by caffeinate, powerd)
     displaysleep         10
     womp                 1
    """

    @Test func parseSleepDisabledAbsentMeansEnabled() {
        #expect(!SleepController.parseSleepDisabled(fromPmsetOutput: pmsetOutputNormal))
    }

    @Test func parseSleepDisabledOne() {
        let output = pmsetOutputNormal + "\n SleepDisabled\t\t1"
        #expect(SleepController.parseSleepDisabled(fromPmsetOutput: output))
    }

    @Test func parseSleepDisabledZero() {
        let output = pmsetOutputNormal + "\n SleepDisabled\t\t0"
        #expect(!SleepController.parseSleepDisabled(fromPmsetOutput: output))
    }

    @Test func parseSleepDisabledEmptyOutput() {
        #expect(!SleepController.parseSleepDisabled(fromPmsetOutput: ""))
    }

    // MARK: - Sudoers rule

    @Test func sudoersRuleGrantsExactlyTheTwoPmsetCommands() {
        let rule = SleepController.sudoersRule(for: "alice")

        #expect(rule.hasPrefix("alice ALL=(root) NOPASSWD: "))
        #expect(rule.contains("/usr/bin/pmset -a disablesleep 1"))
        #expect(rule.contains("/usr/bin/pmset -a disablesleep 0"))
        #expect(rule.hasSuffix("\n"))
        // One line, one grant — nothing else may sneak in
        #expect(rule.filter { $0 == "\n" }.count == 1)
        #expect(rule.components(separatedBy: "pmset").count - 1 == 2)
    }

    /// The generated rule must pass the real visudo syntax check — this is
    /// what --setup-lid runs before installing into /etc/sudoers.d
    @Test func sudoersRulePassesVisudoValidation() throws {
        let rule = SleepController.sudoersRule(for: NSUserName())
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackout-test-sudoers-\(UUID().uuidString)")
        try rule.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        process.arguments = ["-c", "-q", "-f", tempFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "visudo rejected the generated sudoers rule")
    }

    // MARK: - Process liveness

    @Test func isProcessRunningForCurrentProcess() {
        #expect(SleepController.isProcessRunning(pid: ProcessInfo.processInfo.processIdentifier))
    }

    @Test func isProcessRunningForExitedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        #expect(!SleepController.isProcessRunning(pid: process.processIdentifier))
    }
}
