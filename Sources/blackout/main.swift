import Foundation
import BlackoutCore

// Main entry point for the blackout CLI. Parses the command, hands it to
// BlackoutCore and prints the result; the logic lives in the library.

let helpText = """
blackout - black out the screen while the Mac keeps working

Usage:
  blackout [toggle|on|off] [options]   Toggle is the default
  blackout status                      What is on, the settings, the setup
  blackout config [<key> <value>]      Show the saved settings, or change one
  blackout hotkey [default]            Pick a new global shortcut, or go back to the default
  blackout install                     Install the menu bar app and hotkey (via 'make install')
  blackout uninstall                   Remove the menu bar app and hotkey
  blackout setup-lid                   One-time setup so blackout can keep the Mac awake
                                       with the lid closed (writes /etc/sudoers.d/blackout)
  blackout help

Options, for this run only (the saved settings apply otherwise):
  -e, --dim-external / --no-dim-external   Dim external monitors too, or leave them on
      --mute / -m, --no-mute               Mute audio, or leave it on
      --lid / -l, --no-lid                 Keep awake with the lid closed, or not
      --lock / -k, --no-lock               Lock the screen when the lid closes, or not

Settings (blackout config <key> <value>):
  mute           auto|always|never   auto mutes only without an external display
  dim-external   on|off
  builtin-off    on|off              docked, switch the built-in display off instead of
                                     dimming it, so notifications show on the external one
  lid            on|off
  lock           on|off
  notifications  on|off

When on: dims the screen, mutes audio, prevents sleep (even with the lid
closed, after setup-lid) and locks the screen when the lid closes. Unlocking
then ends blackout. Turning it off restores everything.

The global shortcut (when the menu bar app is installed) is ⌃⌥⌘\\ unless you
changed it; 'blackout status' shows the current one.
"""

func printStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printIndented(_ lines: [String]) {
    for line in lines {
        print("  \(line)")
    }
}

func turnOn(_ overrides: Overrides) {
    let settings = overrides.applied(to: Settings.load())
    switch Session().enable(settings: settings) {
    case .enabled(let report):
        print("Blackout is on")
        printIndented(SessionText.sessionLines(
            state: report.state,
            externalOnline: ExternalDisplayController.isExternalDisplayOnline()
        ))
        print("  Run 'blackout' again to turn it off")
    case .alreadyOn:
        print("Blackout is already on")
    case .busy:
        printStandardError("Another blackout command is still running — try again in a moment")
        exit(1)
    case .cancelled:
        printStandardError("Blackout was turned off while it was still turning on")
        exit(1)
    case .failed(let message):
        printStandardError(message)
        exit(1)
    }
}

func turnOff() {
    switch Session().disable(notify: Settings.load().notifications) {
    case .disabled(let report):
        let state = report.state
        if report.recoveredStaleSession {
            print("Recovering stale session (caffeinate was no longer running)")
        }
        print("Blackout is off")
        print("  Brightness restored to \(Int((state.originalBrightness * 100).rounded()))%")
        if let luminance = state.externalLuminance {
            print("  External display restored to \(luminance)%")
        }
        if let volume = state.originalVolume {
            print("  Volume restored to \(volume)%")
        }
        if report.lidSleepRestoreFailed {
            print("  WARNING: could not re-enable sleep!")
            print("  Your Mac will NOT sleep until you run: sudo pmset -a disablesleep 0")
        } else if state.sleepDisabled == true {
            print("  Lid sleep re-enabled")
        }
    case .alreadyOff:
        print("Blackout is already off")
    case .corruptState:
        printStandardError("State file is corrupt — clearing it.")
        printStandardError("Brightness, volume, or sleep settings may need manual restoring.")
        exit(1)
    }
}

func showStatus() {
    let state = StateManager.loadState()
    print(SessionText.headline(state: state, stateFileExists: StateManager.hasState(), now: Date()))
    if let state {
        printIndented(SessionText.sessionLines(
            state: state,
            externalOnline: ExternalDisplayController.isExternalDisplayOnline()
        ))
    }

    print("")
    print("Settings (change with 'blackout config <key> <value>')")
    printIndented(SessionText.settingsLines(Settings.load()))

    let health = Health.check()
    print("")
    print("Setup")
    print("  Lid-closed mode: \(health.lidSetupInstalled ? "ready" : "not set up (run 'blackout setup-lid')")")
    print("  m1ddc: \(health.m1ddcInstalled ? "installed" : "not installed (needed to see and dim an external display)")")
    print("  Screen lock: \(health.lockAvailable ? "available" : "unavailable (macOS lock call missing)")")
    if SleepController.isSleepDisabled() {
        print("  Note: system sleep is currently disabled")
    }

    print("")
    for line in AppInstaller.statusLines() {
        print(line)
    }
}

func setConfig(key: String, value: String) {
    var settings = Settings.load()
    guard settings.set(key: key, value: value) else {
        printStandardError("Cannot set '\(key)' to '\(value)'. The settings and their values:")
        for line in SessionText.settingsLines(settings) {
            printStandardError("  \(line)")
        }
        exit(2)
    }
    guard settings.save() else {
        printStandardError("Could not write \(Settings.fileURL.path)")
        exit(1)
    }
    print(SessionText.settingsLines(settings)[Settings.keys.firstIndex(of: key) ?? 0])
    if StateManager.hasState() {
        print("Blackout is on: this applies the next time it turns on.")
    }
}

func changeHotkey(reset: Bool) {
    var settings = Settings.load()
    if reset {
        settings.hotkey = .default
        guard settings.save() else {
            printStandardError("Could not write \(Settings.fileURL.path)")
            exit(1)
        }
        print("Hotkey is \(settings.hotkey.display) again")
        return
    }

    print("Hotkey is \(settings.hotkey.display)")
    // Recording a shortcut needs a window to press it in, and only the
    // menu bar app has one
    guard AppInstaller.runningMenuAppPID() != nil else {
        printStandardError("The menu bar app is not running, so there is nowhere to press a new shortcut.")
        printStandardError("Start it with 'make install' in the repository, or use 'blackout hotkey default'.")
        exit(1)
    }
    ChangeNotifier.requestHotkeyRecorder()
    print("Press the new shortcut in the Blackout Hotkey window.")
}

/// The detached watcher a session spawns. Not in the help — users never run
/// it directly, but it is visible in `ps` as `blackout --lid-watch`.
func watchLid() -> Never {
    let session = Session()
    func act(_ action: Session.WatcherAction) {
        if action == .stop { exit(0) }
    }
    let watching = LidLockController.watch(
        onLidClose: { act(session.handleLidClose()) },
        onLidOpen: { screenLocked in act(session.handleLidOpen(screenLocked: screenLocked)) },
        onUnlock: { act(session.handleUnlock(notify: Settings.load().notifications)) },
        onDisplaysChanged: { act(session.handleDisplaysChanged()) }
    )
    exit(watching ? 0 : 1)
}

switch CommandLineParser.parse(Array(CommandLine.arguments.dropFirst())) {
case .failure(let error):
    printStandardError(error.message)
    printStandardError("Run 'blackout help' for usage.")
    exit(2)

case .success(let command):
    switch command {
    case .toggle(let overrides):
        // Direction is read here, before waiting for the session lock, and
        // each action is a no-op if already done: two toggles fired together
        // then collapse into one instead of turning on and straight off
        if StateManager.hasState() {
            turnOff()
        } else {
            turnOn(overrides)
        }
    case .on(let overrides):
        turnOn(overrides)
    case .off:
        turnOff()
    case .status:
        showStatus()
    case .configShow:
        for line in SessionText.settingsLines(Settings.load()) {
            print(line)
        }
    case .configSet(let key, let value):
        setConfig(key: key, value: value)
    case .hotkey(let reset):
        changeHotkey(reset: reset)
    case .install:
        AppInstaller.install()
    case .uninstall:
        AppInstaller.uninstall()
    case .setupLid:
        SleepController.setupLid()
    case .lidWatch:
        watchLid()
    case .help:
        print(helpText)
    }
}
