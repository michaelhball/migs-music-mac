import AppKit
import Sparkle
import SwiftUI

@main
struct MigsMusicMacApp: App {
    @NSApplicationDelegateAdaptor(MigsAppDelegate.self) private var delegate

    @StateObject private var model = AppModel()

    var body: some Scene {
        // Window-style menu bar item: clicking the status item shows a popover-like window
        // we control fully (vs. .menu which is a list of menu items). Gives us a real
        // SwiftUI surface for the playlist list, progress, etc.
        MenuBarExtra("migs music", systemImage: "music.note.list") {
            ContentView(
                model: model,
                updater: delegate.updaterController.updater,
                updateState: delegate.updateState
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// AppDelegate exists purely to own the long-lived Sparkle controller and its delegate.
/// SwiftUI's `App` struct is value-type and is reconstructed on each scene update; storing
/// the controller there means a fresh updater (and a fresh @StateObject delegate) every
/// time, which loses Sparkle's in-flight check state. AppDelegate is a class that's
/// instantiated once at app launch and never re-created — the right home.
final class MigsAppDelegate: NSObject, NSApplicationDelegate {
    let updateState = UpdateState()
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: updateState,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_: Notification) {
        // Touch the lazy property so Sparkle's first background check kicks off
        // immediately. Without this, the controller is initialised lazily on
        // first popover render — fine for "Check now" but means automatic
        // checks don't start until the user opens the menu.
        _ = updaterController
    }
}
