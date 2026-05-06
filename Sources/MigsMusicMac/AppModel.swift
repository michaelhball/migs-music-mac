import Foundation
import SwiftUI

/// View state for the menu bar app. Drives the playlist list, selection, sync progress, and
/// device status.
@MainActor
final class AppModel: ObservableObject {
    // MARK: - Device

    @Published var deviceState: DeviceState = .noDevice

    // MARK: - Playlists

    @Published var playlists: [MusicPlaylist] = []
    @Published var loadingPlaylists: Bool = false
    @Published var playlistsError: String?

    /// Names of playlists currently selected for sync. Persisted across app launches via
    /// UserDefaults so the user doesn't have to re-tick every checkbox after a restart.
    @Published var selected: Set<String> = AppModel.loadSelected() {
        didSet { AppModel.saveSelected(selected) }
    }

    /// If true, when a sync removes a playlist from the phone, also delete its audio files
    /// (for songs that aren't referenced by any other synced or manual playlist). Off by
    /// default — the destructive operation should be opt-in. Persisted across launches.
    @Published var deleteOrphanedAudio: Bool = AppModel.loadDeleteOrphans() {
        didSet { AppModel.saveDeleteOrphans(deleteOrphanedAudio) }
    }

    // MARK: - Sync

    @Published var syncing: Bool = false
    /// 1-indexed; `currentSyncStep / totalSyncSteps` drives the progress label.
    @Published var currentSyncStep: Int = 0
    @Published var totalSyncSteps: Int = 0
    @Published var currentSyncName: String = ""
    @Published var lastResults: [SyncResult] = []

    // MARK: - Lifecycle

    init() {
        Task { await refreshDevice() }
        Task { await refreshPlaylists() }
    }

    // MARK: - Actions

    func refreshDevice() async {
        let state = await ADBService.deviceState()
        self.deviceState = state
    }

    func refreshPlaylists() async {
        self.loadingPlaylists = true
        self.playlistsError = nil
        let result = await MusicAppService.listPlaylists()
        self.loadingPlaylists = false
        switch result {
        case .success(let list):
            self.playlists = list
            // Drop any stale selections referring to playlists that no longer exist.
            let liveNames = Set(list.map { $0.name })
            self.selected = self.selected.intersection(liveNames)
        case .failure(let error):
            self.playlistsError = error.localizedDescription
        }
    }

    func toggle(_ name: String) {
        if selected.contains(name) {
            selected.remove(name)
        } else {
            selected.insert(name)
        }
    }

    var canSync: Bool {
        if syncing { return false }
        if selected.isEmpty { return false }
        if case .connected = deviceState { return true }
        return false
    }

    func syncSelected() async {
        guard canSync else { return }
        let toSync = playlists.filter { selected.contains($0.name) }.map { $0.name }
        if toSync.isEmpty { return }

        self.syncing = true
        self.totalSyncSteps = toSync.count
        self.currentSyncStep = 0
        self.lastResults = []

        let results = await SyncOrchestrator.syncMany(
            playlistNames: toSync,
            deleteOrphanedAudio: deleteOrphanedAudio
        ) { [weak self] index, total, name in
            guard let self = self else { return }
            self.currentSyncStep = index + 1
            self.totalSyncSteps = total
            self.currentSyncName = name
        }

        self.lastResults = results
        self.currentSyncName = ""
        self.syncing = false
    }

    // MARK: - Persistence

    private static let selectedKey = "selectedPlaylists"

    private static func loadSelected() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: selectedKey) ?? []
        return Set(array)
    }

    private static func saveSelected(_ selected: Set<String>) {
        UserDefaults.standard.set(Array(selected), forKey: selectedKey)
    }

    private static let deleteOrphansKey = "deleteOrphanedAudio"

    private static func loadDeleteOrphans() -> Bool {
        UserDefaults.standard.bool(forKey: deleteOrphansKey)
    }

    private static func saveDeleteOrphans(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: deleteOrphansKey)
    }
}
