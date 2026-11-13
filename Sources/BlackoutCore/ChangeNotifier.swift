import Foundation
import notify

/// Tells the menu bar app that the session or the settings changed, so its
/// icon follows a toggle made from the terminal or by the lid watcher. A
/// Darwin notification because the poster is usually a short-lived CLI
/// process with no run loop, and a missed post costs nothing: the menu
/// re-reads the files every time it opens.
public enum ChangeNotifier {

    public static let name = "com.blackout.changed"

    public static func post() {
        notify_post(name)
    }

    /// Call `handler` on the main queue after every post, for the life of
    /// the process
    public static func observe(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, DispatchQueue.main) { _ in
            handler()
        }
    }
}
