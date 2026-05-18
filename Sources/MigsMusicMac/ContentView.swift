import Sparkle
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @ObservedObject var updateState: UpdateState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(model: model)
            Divider()
            PlaylistListView(model: model)
            Divider()
            FooterView(model: model, updater: updater, updateState: updateState)
        }
        .padding(12)
        .frame(width: 320, height: 460)
        // Poll the ADB device state while the menu is visible so plugging in a phone after
        // opening the popover updates the UI without a manual refresh. .task is cancelled
        // automatically when the view disappears (popover closes), so polling stops too.
        //
        // Adaptive interval: 3s while the state is changing (responsive when the user
        // plugs/unplugs), backing off up to 30s when the state has been steady. Resets
        // to 3s on any change. Cuts adb invocations to a small fraction with no
        // noticeable UX cost — plugging in still registers within a few seconds.
        .task {
            var lastState: DeviceState? = nil
            var intervalSeconds: Double = 3
            while !Task.isCancelled {
                await model.refreshDevice()
                let current = model.deviceState
                if current == lastState {
                    intervalSeconds = min(intervalSeconds * 1.5, 30)
                } else {
                    intervalSeconds = 3
                    lastState = current
                }
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "music.note.list")
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("migs music").font(.headline)
                deviceLabel
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            // No manual "Check phone" button — USBDeviceMonitor watches IOKit and
            // calls refreshDevice immediately on attach/detach (~100ms), so the
            // device-state label updates the moment a phone is plugged in or
            // unplugged. The polling loop in ContentView.task is a defensive
            // fallback in case IOKit notifications miss something.
        }
    }

    private var deviceLabel: Text {
        switch model.deviceState {
        case .connected(let serial):
            return Text("Connected · \(serial)")
        case .noDevice:
            return Text("No device — plug in via USB")
        case .unauthorized:
            return Text("Unauthorised — accept the dialog on your phone")
        case .noAdb:
            return Text("adb not found — install Android platform-tools")
        }
    }
}

private struct PlaylistListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.loadingPlaylists {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading playlists from Music…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if let error = model.playlistsError {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't load playlists").font(.subheadline)
                Text(error).font(.caption).foregroundColor(.secondary)
                Button("Retry") {
                    Task { await model.refreshPlaylists() }
                }
                .buttonStyle(.bordered)
            }
        } else if model.playlists.isEmpty {
            Text("No user playlists in Music.app.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Search field only when there are enough playlists for it to be useful
                // (below ~10 you scan visually faster). No manual reload button — the
                // FSEvents watcher refreshes the list within ~200ms of any Music.app edit.
                if model.playlists.count > 10 {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search playlists", text: $model.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }

                let visible = model.visiblePlaylists
                if visible.isEmpty {
                    Text("No playlists match \"\(model.searchQuery)\".")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(visible) { playlist in
                                PlaylistRow(playlist: playlist, model: model)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PlaylistRow: View {
    let playlist: MusicPlaylist
    @ObservedObject var model: AppModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.selected.contains(playlist.name) },
            set: { _ in model.toggle(playlist.name) }
        )) {
            HStack(spacing: 6) {
                Text(playlist.name).lineLimit(1).truncationMode(.tail)
                Spacer()
                syncStatusIcon
                Text("\(playlist.trackCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }

    /// Tiny indicator that says, at a glance, whether this playlist's current contents
    /// match what was last pushed to the phone. The icon is intentionally subtle —
    /// .caption2-sized, secondary tint when "stale", primary when "synced", orange when
    /// "pending". `neverSynced` shows nothing so empty rows stay clean.
    @ViewBuilder
    private var syncStatusIcon: some View {
        // Only show the indicator when a phone is actually connected. The status
        // refers to "synced with this phone" — without a phone it's ambiguous
        // (which phone? a different one next time? Mac↔Music.app, perhaps?).
        // Hiding it on disconnect makes the affordance unambiguous: dots only
        // mean "phone-side sync state".
        if case .connected = model.deviceState {
            let state = model.syncState(for: playlist)
            switch state {
            case .synced:
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundColor(.green)
                    .help("Synced — phone matches Music.")
            case .pending:
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundColor(.orange)
                    .help("Pending — contents differ from last sync, or never synced. Click Sync to push.")
            case .stale:
                Image(systemName: "minus.circle.fill")
                    .imageScale(.small)
                    .foregroundColor(.secondary)
                    .help("Will be removed from the phone on next Sync.")
            case .neverSynced:
                EmptyView()
            }
        }
    }
}

private struct FooterView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @ObservedObject var updateState: UpdateState

    /// Reads CFBundleShortVersionString from the running .app's Info.plist. Falls back
    /// to "?" if for some reason it's not set (shouldn't happen in a built bundle).
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Tooltip text for the Sync button — explains why it's disabled when applicable. The
    /// button itself shows the playlist count, so the disabled state isn't self-explanatory.
    private var syncHelpText: String {
        if model.syncing { return "Sync in progress." }
        if model.selected.isEmpty { return "Tick at least one playlist above to enable Sync." }
        switch model.deviceState {
        case .connected: return "Push the ticked playlists to the connected phone."
        case .noDevice: return "Plug your phone in via USB to enable Sync."
        case .unauthorized: return "Accept the USB-debugging dialog on your phone, then click Refresh."
        case .noAdb: return "Install Android platform-tools (e.g. `brew install android-platform-tools`)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Destructive option: when removing a synced playlist from the phone, also
            // delete its audio files (only the ones not referenced by any other playlist).
            // Off by default; persisted across app restarts.
            Toggle(isOn: $model.deleteOrphanedAudio) {
                Text("Delete audio files when unsynced")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("When a previously-synced playlist is unchecked, also remove its audio files from the phone — but only songs not used by any other playlist.")

            if model.syncing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Syncing \(model.currentSyncStep) of \(model.totalSyncSteps): \(model.currentSyncName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if !model.lastResults.isEmpty {
                let succeeded = model.lastResults.filter { $0.success }.count
                let failed = model.lastResults.count - succeeded
                Text(failed == 0
                    ? "Synced \(succeeded) playlist\(succeeded == 1 ? "" : "s")"
                    : "Synced \(succeeded), \(failed) failed")
                    .font(.caption)
                    .foregroundColor(failed == 0 ? .secondary : .red)
                let failures = model.lastResults.filter { !$0.success }
                ForEach(failures) { result in
                    Text("✗ \(result.playlistName)").font(.caption2).foregroundColor(.red)
                }
                // Surface the sync script's combined output so a failure is
                // actually diagnosable from the popover — previously the UI
                // showed only the red playlist names with no hint of *why*
                // they failed. Every failed result carries the same combined
                // log, so show it once.
                if let raw = failures.first?.output {
                    let detail = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !detail.isEmpty {
                        ScrollView {
                            Text(detail)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(maxHeight: 140)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            HStack {
                Button {
                    Task { await model.syncSelected() }
                } label: {
                    if model.syncing {
                        Label("Syncing…", systemImage: "iphone.and.arrow.forward")
                    } else {
                        let n = model.selected.count
                        Label(
                            "Sync \(n) to phone",
                            systemImage: "iphone.and.arrow.forward"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSync)
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(syncHelpText) (⌘↩)")

                Spacer()

                // When Sparkle's silent background check has surfaced a newer version
                // we swap the version label for an "Update available" affordance. The
                // tap target is the same — clicking opens Sparkle's install dialog —
                // but the copy now tells the user something happened.
                if let staged = updateState.availableVersion {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("Update available", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("migs music v\(staged) is available. Click to install.")
                    .padding(.trailing, 4)
                } else {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Text("v\(appVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("migs music \(appVersion). Click to check for updates. Sparkle also checks once a day automatically.")
                    .padding(.trailing, 4)
                }

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}
