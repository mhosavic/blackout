import Foundation

/// Serializes starting and ending a session across processes: the CLI, the
/// menu bar app's child and the lid watcher can all act within the same
/// second, and two enables that both see "off" would start two caffeinates,
/// one of them orphaned for good.
///
/// An flock on a file, so the kernel releases it when the holder exits or is
/// killed — the lid watcher is SIGTERMed mid-session as a matter of course.
public enum SessionLock {

    /// Overridable so tests can use a temporary directory
    public static var fileURL: URL = PathManager.lockFile

    /// How long to wait for another blackout command before deciding it hung
    public static var timeout: TimeInterval = 10

    /// Run `body` holding the lock. Returns nil, without running it, if
    /// another command still held the lock after `timeout`.
    public static func withLock<T>(waitingAtMost limit: TimeInterval? = nil, _ body: () -> T) -> T? {
        return run(body, proceedOnTimeout: false, limit: limit ?? timeout)
    }

    /// Run `body` holding the lock, or without it if another command still
    /// held it after `timeout`. For turning blackout off, which must never be
    /// refused — a black screen with no way back is worse than a restore that
    /// runs twice.
    public static func withLockOrProceed<T>(_ body: () -> T) -> T {
        // Never nil: proceedOnTimeout always runs the body
        return run(body, proceedOnTimeout: true, limit: timeout)!
    }

    private static func run<T>(_ body: () -> T, proceedOnTimeout: Bool, limit: TimeInterval) -> T? {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // O_CLOEXEC so a child that outlives us (caffeinate, the watcher)
        // cannot inherit the descriptor and keep the lock held all session
        let fd = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        // No lock file is no reason to refuse to work
        guard fd >= 0 else { return body() }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(limit)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                return proceedOnTimeout ? body() : nil
            }
            usleep(50_000)
        }
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}
