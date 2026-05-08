import Sparkle
import SwiftUI

@main
struct MigsMusicMacApp: App {
    @StateObject private var model = AppModel()
    // Single Sparkle controller for the lifetime of the app. Sparkle handles all the
    // moving parts of an auto-update — fetching the appcast, checking signatures, asking
    // the user, downloading, swapping the bundle, relaunching — once we hand it the
    // public-key + feed URL via Info.plist (see SUPublicEDKey, SUFeedURL).
    private let updaterController =
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        // Window-style menu bar item: clicking the status item shows a popover-like window
        // we control fully (vs. .menu which is a list of menu items). Gives us a real
        // SwiftUI surface for the playlist list, progress, etc.
        MenuBarExtra("migs music", systemImage: "music.note.list") {
            ContentView(model: model, updater: updaterController.updater)
        }
        .menuBarExtraStyle(.window)
    }
}
