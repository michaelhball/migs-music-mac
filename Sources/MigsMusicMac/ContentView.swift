import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(model: model)
            Divider()
            PlaylistListView(model: model)
            Divider()
            FooterView(model: model)
        }
        .padding(12)
        .frame(width: 320, height: 460)
    }
}

private struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "music.note.list")
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("MIGS Sync").font(.headline)
                deviceLabel
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refreshDevice() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-check device + reload playlists")
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
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.playlists) { playlist in
                        PlaylistRow(playlist: playlist, model: model)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.syncing {
                HStack {
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
                    ? "✓ Synced \(succeeded) playlist\(succeeded == 1 ? "" : "s")"
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

                Spacer()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}
