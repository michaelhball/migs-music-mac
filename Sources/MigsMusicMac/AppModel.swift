import Foundation
import SwiftUI

/// View state for the menu bar app. Drives the playlist list, selection, sync progress, and
/// device status.
@MainActor
final class AppModel: ObservableObject {
    // MARK: - Device

    @Published var deviceState: DeviceState = .noDevice

    // MARK: - Playlists

    /// Hydrated from UserDefaults at init so app launch feels instant — the popover
    /// shows the previous session's list immediately, then we refresh in the background.
    /// On a clean install this is empty and we fall back to the spinner UX.
    @Published var playlists: [MusicPlaylist] = AppModel.loadCachedPlaylists()
    @Published var loadingPlaylists: Bool = false
    @Published var playlistsError: String?

    /// Filter text typed into the search field; case-insensitive substring match against
    /// playlist names. Empty string = show everything. Not persisted — every fresh popover
    /// open starts with no filter.
    @Published var searchQuery: String = ""

    /// Playlists filtered by [searchQuery]. The view consumes this instead of [playlists]
    /// directly so the filter is applied in one place.
    var visiblePlaylists: [MusicPlaylist] {
        if searchQuery.isEmpty { return playlists }
        let query = searchQuery.lowercased()
        return playlists.filter { $0.name.lowercased().contains(query) }
    }

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

    // MARK: - Updates

    /// Latest GitHub release if it's newer than the running version. Drives the in-app
    /// update banner. nil = no banner (either we're up-to-date or the check hasn't run /
    /// has failed silently).
    @Published var availableUpdate: AvailableUpdate?

    // MARK: - Lifecycle

    init() {
        Task { await refreshDevice() }
        Task { await refreshPlaylists() }
        Task { await checkForUpdate() }
    }

    // MARK: - Actions

    func refreshDevice() async {
        let state = await ADBService.deviceState()
        self.deviceState = state
    }

    /// Re-entrancy guard so mashing the Refresh button doesn't kick off overlapping
    /// AppleScript invocations. Without this, a second click while the first is in flight
    /// would: (a) flicker the loading spinner state on→off→on, and (b) waste a second
    /// 200-1000ms Music.app round trip whose result clobbers the first's. Single-flight
    /// is the correct semantic — concurrent callers all observe the same fresh data.
    private var refreshPlaylistsInFlight: Bool = false

    func refreshPlaylists() async {
        guard !refreshPlaylistsInFlight else { return }
        refreshPlaylistsInFlight = true
        defer { refreshPlaylistsInFlight = false }

        // Only show the spinner if we have nothing to display. With a cached list from
        // the previous session we'd rather keep showing it while we refresh silently —
        // the spinner-then-list flicker is worse UX than a few seconds of slightly-stale data.
        let hasCached = !self.playlists.isEmpty
        if !hasCached { self.loadingPlaylists = true }
        self.playlistsError = nil
        let result = await MusicAppService.listPlaylists()
        self.loadingPlaylists = false
        switch result {
        case .success(let list):
            self.playlists = list
            AppModel.saveCachedPlaylists(list)
            // Drop any stale selections referring to playlists that no longer exist.
            let liveNames = Set(list.map { $0.name })
            self.selected = self.selected.intersection(liveNames)
        case .failure(let error):
            // Surface the error only if we have no cached data to fall back on. Silent
            // failure with cached data is intentional — Refresh button retries on demand.
            if !hasCached {
                self.playlistsError = error.localizedDescription
            }
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

    /// Throttled to once per 6 hours via UserDefaults — the menu opens dozens of times a
    /// day and we don't need GitHub-API hits on every popover. The throttle timestamp
    /// only advances on a *successful* HTTP response, so a transient network failure
    /// doesn't silence the check for hours; we'll retry on the next launch.
    func checkForUpdate() async {
        let key = "lastUpdateCheckAt"
        let now = Date()
        if let last = UserDefaults.standard.object(forKey: key) as? Date,
           now.timeIntervalSince(last) < 6 * 60 * 60 {
            return
        }
        switch await UpdateChecker.check() {
        case .update(let update):
            self.availableUpdate = update
            UserDefaults.standard.set(now, forKey: key)
        case .upToDate:
            self.availableUpdate = nil
            UserDefaults.standard.set(now, forKey: key)
        case .failed:
            break
        }
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

    private static let playlistsCacheKey = "cachedPlaylists"

    /// Decoded best-effort. If MusicPlaylist's schema ever changes incompatibly, the
    /// decode fails silently and we fall back to a clean fetch — no migration needed.
    private static func loadCachedPlaylists() -> [MusicPlaylist] {
        guard
            let data = UserDefaults.standard.data(forKey: playlistsCacheKey),
            let list = try? JSONDecoder().decode([MusicPlaylist].self, from: data)
        else { return [] }
        return list
    }

    private static func saveCachedPlaylists(_ list: [MusicPlaylist]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: playlistsCacheKey)
    }
}
