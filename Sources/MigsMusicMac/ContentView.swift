import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let update = model.availableUpdate {
                UpdateBanner(update: update)
            }
            HeaderView(model: model)
            Divider()
            PlaylistListView(model: model)
            Divider()
            FooterView(model: model)
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

private struct UpdateBanner: View {
    let update: AvailableUpdate

    var body: some View {
        Button {
            NSWorkspace.shared.open(update.releaseURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Update available — v\(update.version)")
                    .font(.caption)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .imageScale(.small)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the v\(update.version) release notes — has install instructions for both Homebrew and direct download.")
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
            // Re-check the connected ADB device. Live-polling already does this every few
            // seconds while the popover is open; this button is the manual escape hatch
            // for "I just plugged in / accepted the auth dialog and want it now".
            Button {
                Task { await model.refreshDevice() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("Re-check phone connection (⌘R)")
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
                // Search + manual reload row. Search field only when there are enough
                // playlists for it to be useful (below ~10 you scan visually faster);
                // the reload button is always shown so the user has an explicit way to
                // pull in edits made in Music.app since the last refresh.
                HStack(spacing: 6) {
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
                    } else {
                        Spacer()
                    }
                    Button {
                        Task { await model.refreshPlaylists() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Reload playlists from Music.app — picks up edits made since the last refresh.")
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
            HStack {
                Text(playlist.name).lineLimit(1).truncationMode(.tail)
                Spacer()
                Text("\(playlist.trackCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }
}

private struct FooterView: View {
    @ObservedObject var model: AppModel

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
                ForEach(model.lastResults.filter { !$0.success }) { result in
                    Text("✗ \(result.playlistName)").font(.caption2).foregroundColor(.red)
                }
            }

            HStack {
                Button {
                    Task { await model.syncSelected() }
                } label: {
                    if model.syncing {
                        Text("Syncing…")
                    } else {
                        Text("Sync \(model.selected.count) playlist\(model.selected.count == 1 ? "" : "s")")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSync)
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(syncHelpText) (⌘↩)")

                Spacer()

                Text("v\(appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("migs music \(appVersion)")
                    .padding(.trailing, 4)

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}
