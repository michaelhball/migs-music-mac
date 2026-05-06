import SwiftUI

@main
struct MigsMusicMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Window-style menu bar item: clicking the status item shows a popover-like window
        // we control fully (vs. .menu which is a list of menu items). Gives us a real
        // SwiftUI surface for the playlist list, progress, etc.
        MenuBarExtra("migs music", systemImage: "music.note.list") {
            ContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
