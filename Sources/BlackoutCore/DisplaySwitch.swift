import Foundation
import CoreGraphics

/// Switching a display off and on, as closing the lid does for the built-in
/// one: macOS stops treating it as a screen, moves its windows to the
/// remaining display and makes that one the main display — which is where
/// notification banners appear.
///
/// Uses CGSConfigureDisplayEnabled, an undocumented CoreGraphics call,
/// resolved at runtime like the brightness and lock calls so that a macOS
/// update which removes it degrades to "dimmed instead" rather than a binary
/// that will not launch.
public enum DisplaySwitch {

    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32

    private static let configureEnabled: ConfigureEnabled? = {
        // RTLD_DEFAULT: search every image already loaded
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureEnabled.self)
    }()

    /// Whether this macOS can switch a display off at all
    public static func isAvailable() -> Bool {
        return configureEnabled != nil
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The built-in display's ID while it is online; nil while it is
    /// switched off or the lid is shut
    public static func builtinDisplayID() -> CGDirectDisplayID? {
        return onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// A display may be switched off only while another one stays on:
    /// whatever else goes wrong, the Mac must never be left with no screen
    public static func maySwitchOff(_ display: CGDirectDisplayID, online: [CGDirectDisplayID]) -> Bool {
        return online.contains(display) && online.count > 1
    }

    /// Switch a display off or on. Returns whether it ended up as asked.
    /// The change lasts for the login session at most: logging out or
    /// restarting always brings every display back.
    public static func setEnabled(_ display: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        guard let configureEnabled else { return false }
        if !enabled && !maySwitchOff(display, online: onlineDisplays()) { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard configureEnabled(config, display, enabled) == 0 else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { return false }

        guard enabled else { return true }
        // A display takes a moment to come back; callers go on to set its
        // brightness, which only works once it is listed again
        let deadline = Date().addingTimeInterval(2)
        while !onlineDisplays().contains(display) {
            if Date() >= deadline { return false }
            usleep(50_000)
        }
        return true
    }
}

/// Calls `handler` on the main queue after the set of displays changes — a
/// monitor plugged or unplugged, the lid opened, a display switched off.
/// One change raises several system callbacks, so they are collected into a
/// single call once things have settled.
public final class DisplayChangeObserver {

    private let handler: () -> Void
    private var pending: DispatchWorkItem?

    public init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Start observing. The observer must stay referenced for as long as
    /// changes should be reported.
    public func start() {
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            // Called once before and once after each change; only the
            // "after" call describes the new arrangement
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let observer = Unmanaged<DisplayChangeObserver>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { observer.schedule() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func schedule() {
        pending?.cancel()
        let call = DispatchWorkItem { [weak self] in self?.handler() }
        pending = call
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: call)
    }
}
