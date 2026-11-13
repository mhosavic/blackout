import AppKit
import BlackoutCore

/// The icon in the menu bar and its menu. Holds no state of its own about
/// blackout: the icon and the menu are redrawn from the state and settings
/// files, so they cannot drift from what the CLI or the lid watcher did.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let toggler: Toggler
    private let onChangeHotkey: () -> Void
    /// The shortcut shown beside Turn On / Turn Off, as of the last build
    private var shownHotkey = Hotkey.default

    private var shownOn: Bool?
    // Assumed fine until the first check lands, so the menu never flashes
    // a warning that is not true
    private var health = Health(lidSetupInstalled: true, m1ddcInstalled: true, lockAvailable: true)
    /// Actions of the menu as last built; an item's tag indexes into it
    private var actions: [MenuAction] = []
    private var refreshTimer: Timer?

    init(toggler: Toggler, onChangeHotkey: @escaping () -> Void) {
        self.toggler = toggler
        self.onChangeHotkey = onChangeHotkey
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        refreshIcon()
        refreshHealth()

        ChangeNotifier.observe { [weak self] in
            self?.refreshIcon()
            self?.refreshHealth()
        }
        // A session can also end without a notification: an older watcher,
        // uninstall.sh or a deleted state file. Checking is one stat().
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
    }

    func refreshIcon() {
        let isOn = StateManager.hasState()
        guard isOn != shownOn else { return }
        shownOn = isOn
        statusItem.button?.image = MenuBarIcon.image(on: isOn)
        statusItem.button?.toolTip = isOn ? "Blackout is on" : "Blackout is off"
        statusItem.button?.setAccessibilityLabel(isOn ? "Blackout, on" : "Blackout, off")
    }

    /// The setup checks spawn `sudo -n -l`, so they run off the main thread
    /// and the menu draws the last known answer
    private func refreshHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let health = Health.check()
            DispatchQueue.main.async {
                self?.health = health
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshIcon()

        let settings = Settings.load()
        shownHotkey = settings.hotkey
        let model = MenuModel.build(
            state: StateManager.loadState(),
            stateFileExists: StateManager.hasState(),
            externalOnline: ExternalDisplayController.isExternalDisplayOnline(),
            settings: settings,
            health: health,
            now: Date()
        )
        actions = []
        menu.removeAllItems()
        for item in model {
            menu.addItem(render(item))
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshHealth()
    }

    // MARK: - Rendering

    private func render(_ model: MenuItemModel) -> NSMenuItem {
        switch model {
        case .separator:
            return .separator()

        case .header(let title):
            return .sectionHeader(title: title)

        case .info(let text):
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item

        case .warning(let text):
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")
            return item

        case .action(let title, let action, let showsHotkey):
            let item = actionItem(title: title, action: action)
            // Shown for reference; the global hotkey itself is registered
            // by HotkeyManager and works with the menu closed. A menu item
            // can only display a single character, so a named key (F5,
            // Space) is left to the "Change Hotkey" line.
            if showsHotkey, shownHotkey.keyLabel.count == 1 {
                item.keyEquivalent = shownHotkey.keyLabel.lowercased()
                var mask: NSEvent.ModifierFlags = []
                if shownHotkey.modifiers & Hotkey.command != 0 { mask.insert(.command) }
                if shownHotkey.modifiers & Hotkey.option != 0 { mask.insert(.option) }
                if shownHotkey.modifiers & Hotkey.control != 0 { mask.insert(.control) }
                if shownHotkey.modifiers & Hotkey.shift != 0 { mask.insert(.shift) }
                item.keyEquivalentModifierMask = mask
            }
            return item

        case .toggle(let title, let action, let isOn):
            let item = actionItem(title: title, action: action)
            item.state = isOn ? .on : .off
            return item

        case .submenu(let title, let children):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in children {
                submenu.addItem(render(child))
            }
            item.submenu = submenu
            return item
        }
    }

    private func actionItem(title: String, action: MenuAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuItemClicked(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        return item
    }

    // MARK: - Actions

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }

        switch actions[sender.tag] {
        case .turnOn:
            toggler.run("on") { [weak self] in self?.refreshIcon() }
        case .turnOff:
            toggler.run("off") { [weak self] in self?.refreshIcon() }
        case .set(let key, let value):
            var settings = Settings.load()
            if settings.set(key: key, value: value), settings.save() {
                Logger.info("Setting changed: \(key) = \(value)")
            } else {
                Logger.error("Could not change setting \(key) to \(value)")
            }
        case .changeHotkey:
            onChangeHotkey()
        case .openLog:
            NSWorkspace.shared.open(PathManager.daemonLog)
        case .quit:
            Logger.info("Quit from the menu")
            removePIDFile()
            exit(0)
        }
    }
}
