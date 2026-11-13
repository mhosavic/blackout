import Testing
import Foundation
import BlackoutCore

extension FileBackedTests {
@Suite final class SessionLockTests {

    private let tempDir: URL
    private let originalFileURL: URL
    private let originalTimeout: TimeInterval

    init() throws {
        originalFileURL = SessionLock.fileURL
        originalTimeout = SessionLock.timeout
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // One level down, so taking the lock also has to create the directory
        SessionLock.fileURL = tempDir.appendingPathComponent("dot-blackout/lock")
    }

    deinit {
        SessionLock.fileURL = originalFileURL
        SessionLock.timeout = originalTimeout
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Hold the lock the way another blackout process would: through its own
    /// open file, which flock treats as a separate owner even in one process
    private func holdLock(for seconds: TimeInterval) throws -> Date {
        try FileManager.default.createDirectory(
            at: SessionLock.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(SessionLock.fileURL.path, O_CREAT | O_RDWR, 0o644)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let releasedAt = Date().addingTimeInterval(seconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return releasedAt
    }

    @Test func runsTheBodyAndReturnsItsValue() {
        #expect(SessionLock.withLock { 42 } == 42)
    }

    @Test func secondLockHolderWaitsForTheFirst() throws {
        SessionLock.timeout = 5
        let releasedAt = try holdLock(for: 0.3)

        let ranAt = try #require(SessionLock.withLock { Date() })

        #expect(ranAt >= releasedAt)
    }

    @Test func givesUpAfterTheTimeout() throws {
        SessionLock.timeout = 0.2
        _ = try holdLock(for: 3)

        var bodyRan = false
        let started = Date()
        let result: Bool? = SessionLock.withLock { bodyRan = true; return true }

        #expect(result == nil)
        #expect(!bodyRan)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    /// A toggle that hangs must not leave the user unable to get their
    /// screen back: turning off waits the same, then goes ahead regardless
    @Test func proceedVariantRunsAfterTheTimeout() throws {
        SessionLock.timeout = 0.2
        _ = try holdLock(for: 3)

        let started = Date()
        let ran = SessionLock.withLockOrProceed { true }

        #expect(ran)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test func lockIsFreeAgainAfterTheBody() {
        SessionLock.timeout = 0.2
        let first: Void? = SessionLock.withLock {}
        let second: Void? = SessionLock.withLock {}
        #expect(first != nil)
        #expect(second != nil)
    }
}
}
