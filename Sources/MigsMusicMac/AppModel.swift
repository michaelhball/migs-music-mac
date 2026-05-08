import Foundation
import iTunesLibrary
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

    /// Snapshot of what we last successfully pushed to the phone, per playlist name.
    /// Drives the per-row sync-status icon: a playlist whose current contentHash matches
    /// its lastSynced.contentHash reads as "synced"; mismatch reads as "pending".
    /// Persisted across launches so the indicator survives quitting the app.
    @Published var lastSynced: [String: LastSynced] = AppModel.loadLastSynced() {
        didSet { AppModel.saveLastSynced(lastSynced) }
    }

    // MARK: - Updates

    /// Latest GitHub release if it's newer than the running version. Drives the in-app
    /// update banner. nil = no banner (either we're up-to-date or the check hasn't run /
    /// has failed silently).
    @Published var availableUpdate: AvailableUpdate?

    // MARK: - Live library subscription

    /// Long-lived ITLibrary instance whose only purpose is to publish change events.
    /// We subscribe to ITLibraryDidChangeNotification on this object — every Music.app
    /// edit (track add/remove/rename, playlist reorder) fires the notification within
    /// a few hundred ms, and we then call `refreshPlaylists` to pick up the change.
    /// No polling, no manual reload required.
    private var liveLibrary: ITLibrary?
    private var liveLibraryObserver: NSObjectProtocol?
    private var liveRefreshTask: Task<Void, Never>?

    // MARK: - USB monitor

    /// Watches IOKit for any USB device attach/detach. Triggers an immediate
    /// refreshDevice on every event, so plug-in / unplug shows up in the
    /// device-state label within ~100ms — no polling, no manual button.
    private var usbMonitor: USBDeviceMonitor?

    // MARK: - Lifecycle

    init() {
        Task { await refreshDevice() }
        Task { await refreshPlaylists() }
        Task { await checkForUpdate() }
        startLiveLibraryUpdates()
        startUSBMonitor()
    }

    deinit {
        if let obs = liveLibraryObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func startUSBMonitor() {
        usbMonitor = USBDeviceMonitor { [weak self] in
            Task { @MainActor in
                await self?.refreshDevice()
            }
        }
    }

    private func startLiveLibraryUpdates() {
        // Holding a long-lived ITLibrary keeps us subscribed to its change notifications.
        // If construction fails (rare — Music.app library file missing or permission denied),
        // we silently fall back to manual-refresh-only behavior.
        guard let lib = try? ITLibrary(apiVersion: "1.0") else { return }
        self.liveLibrary = lib
        liveLibraryObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ITLibraryDidChangeNotification"),
            object: lib,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleLiveRefresh()
        }
    }

    /// Debounced refresh trigger. Music.app can fire the change notification many
    /// times in quick succession (e.g. while a multi-track import lands); we
    /// coalesce to one refresh per ~250ms quiet window.
    private func scheduleLiveRefresh() {
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self?.refreshPlaylists()
        }
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

        // Update the per-playlist sync snapshot for every playlist that actually
        // landed. The snapshot drives the in-row sync-status icon: a later edit
        // in Music.app flips contentHash and the row reads "pending" until the
        // user syncs again.
        var updated = lastSynced
        for r in results where r.success {
            if let pl = playlists.first(where: { $0.name == r.playlistName }) {
                updated[pl.name] = LastSynced(
                    trackCount: pl.trackCount,
                    contentHash: pl.contentHash
                )
            }
        }
        // Drop snapshots for playlists the user un-ticked AND that aren't in this sync —
        // when they next sync without ticking those, the orphan-cleanup path on the phone
        // removes them, and our "stale" indicator disappears too.
        let stillSelected = Set(playlists.filter { selected.contains($0.name) }.map { $0.name })
        for name in updated.keys where !stillSelected.contains(name) {
            updated.removeValue(forKey: name)
        }
        self.lastSynced = updated
    }

    /// Per-row sync state used by the popover UI to render a status icon.
    func syncState(for playlist: MusicPlaylist) -> SyncState {
        let isTicked = selected.contains(playlist.name)
        let snap = lastSynced[playlist.name]
        if !isTicked {
            return snap == nil ? .neverSynced : .stale
        }
        guard let snap = snap else { return .pending }
        return snap.contentHash == playlist.contentHash ? .synced : .pending
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

    private static let lastSyncedKey = "lastSyncedSnapshot"

    private static func loadLastSynced() -> [String: LastSynced] {
        guard
            let data = UserDefaults.standard.data(forKey: lastSyncedKey),
            let dict = try? JSONDecoder().decode([String: LastSynced].self, from: data)
        else { return [:] }
        return dict
    }

    private static func saveLastSynced(_ map: [String: LastSynced]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: lastSyncedKey)
    }
}

/// Per-playlist record of the last successful sync to the phone.
struct LastSynced: Codable, Hashable {
    let trackCount: Int
    let contentHash: String
}

/// Per-row sync state surfaced in the popover.
enum SyncState {
    /// Not ticked, never synced — no icon.
    case neverSynced
    /// Ticked but contents differ from last-pushed snapshot, OR never synced — pending.
    case pending
    /// Ticked and contents match last-pushed snapshot — synced.
    case synced
    /// Not ticked, has a snapshot — will be removed from the phone on next sync.
    case stale
}
