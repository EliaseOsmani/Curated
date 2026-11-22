//
//  MusicPlaylistsVM.swift
//  Retune
//
//  Created by Eliase Osmani on 2/17/26.
//

import Foundation
import Combine
import MusicKit

private enum PlaylistLoadError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Apple Music did not respond. Check Settings → Apple Account → Media & Purchases, then try again."
        }
    }
}

// MARK: - Track paging

nonisolated enum AppleMusicTracks {
    /// Fetches every track in a playlist, following MusicKit's batches.
    static func all(
        in playlist: Playlist,
        onProgress: (@MainActor @Sendable (Int) -> Void)? = nil
    ) async throws -> [Track] {
        let detailed = try await playlist.with([.tracks])
        guard var batch = detailed.tracks else { return [] }

        var tracks = Array(batch)
        await onProgress?(tracks.count)

        while batch.hasNextBatch {
            try Task.checkCancellation()
            guard let next = try await batch.nextBatch() else { break }
            tracks.append(contentsOf: next)
            batch = next
            await onProgress?(tracks.count)
        }
        return tracks
    }
}

// MARK: - MusicPlaylistsVM

@MainActor
final class MusicPlaylistsVM: ObservableObject {
    /// Sorted rows for Home. Built once per load and updated in small batches,
    /// so views never read MusicKit properties while rendering.
    @Published private(set) var selections: [PlaylistSelection] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private(set) var playlists: [Playlist] = []

    private let countsKey = "playlistTrackCounts"
    private let maxConcurrentCounts = 3

    private var loadID = UUID()
    private var hasLoaded = false
    private var sortOption: PlaylistSortOption = .recentlyPlayed

    private var playlistsByID: [String: Playlist] = [:]
    private var countCacheKeys: [String: String] = [:]
    private var cachedCounts: [String: Int]

    private var countQueue: [String] = []
    private var activeCountTasks: [String: Task<Void, Never>] = [:]
    private var attemptedCounts: Set<String> = []
    private var pendingCounts: [String: Int] = [:]
    private var flushTask: Task<Void, Never>?
    private var isCountingPaused = false

    init() {
        cachedCounts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
    }

    // MARK: - Loading

    /// Loads the library once. Returning to Home keeps the existing list.
    func load() async {
        guard !hasLoaded else { return }
        await fetchPlaylists()
    }

    /// Pull-to-refresh.
    func refresh() async {
        // Without a modified date there's no way to tell if a count is stale.
        cachedCounts = cachedCounts.filter { !$0.key.hasSuffix("|none") }
        await fetchPlaylists()
    }

    private func fetchPlaylists() async {
        let currentLoadID = UUID()
        loadID = currentLoadID
        isLoading = selections.isEmpty
        errorMessage = nil

        // Connecting during onboarding already requested permission. Calling
        // request() again here can make MusicKit resolve the Apple account a
        // second time and block the transition into Home.
        let currentStatus = MusicAuthorization.currentStatus
        let status = currentStatus == .notDetermined
            ? await MusicAuthorization.request()
            : currentStatus
        guard status == .authorized else {
            guard loadID == currentLoadID else { return }
            errorMessage = "Apple Music access not authorized."
            isLoading = false
            return
        }

        do {
            let libraryPlaylists = try await fetchLibraryPlaylists()
            guard loadID == currentLoadID else { return }

            apply(libraryPlaylists)
            hasLoaded = true
            isLoading = false
        } catch is CancellationError {
            guard loadID == currentLoadID else { return }
            isLoading = false
        } catch {
            guard loadID == currentLoadID else { return }
            // A failed refresh shouldn't replace a list that's still usable.
            if selections.isEmpty {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func fetchLibraryPlaylists() async throws -> [Playlist] {
        try await withThrowingTaskGroup(of: [Playlist].self) { group in
            group.addTask {
                var request = MusicLibraryRequest<Playlist>()
                request.limit = 50
                let response = try await request.response()

                var batch = response.items
                var all = Array(batch)
                while batch.hasNextBatch {
                    try Task.checkCancellation()
                    guard let next = try await batch.nextBatch() else { break }
                    all.append(contentsOf: next)
                    batch = next
                }
                return all
            }

            group.addTask {
                try await Task.sleep(for: .seconds(15))
                try Task.checkCancellation()
                throw PlaylistLoadError.timedOut
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func apply(_ libraryPlaylists: [Playlist]) {
        cancelCountWork()
        attemptedCounts = []
        playlists = libraryPlaylists
        playlistsByID = Dictionary(
            libraryPlaylists.map { ($0.id.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Counts are valid only until the playlist is next modified.
        var keys: [String: String] = [:]
        var rows: [PlaylistSelection] = []
        for playlist in libraryPlaylists {
            let id = playlist.id.rawValue
            let modified = playlist.lastModifiedDate.map { String($0.timeIntervalSince1970) } ?? "none"
            let key = "\(id)|\(modified)"
            keys[id] = key
            rows.append(PlaylistSelection(appleMusicPlaylist: playlist, trackCount: cachedCounts[key] ?? 0))
        }
        countCacheKeys = keys

        let currentKeys = Set(keys.values)
        cachedCounts = cachedCounts.filter { currentKeys.contains($0.key) }
        saveCounts()

        selections = sortOption.sorted(rows)
        if sortOption.needsTrackCounts { requestAllTrackCounts() }
    }

    // MARK: - Sorting

    func setSortOption(_ option: PlaylistSortOption) {
        guard option != sortOption else { return }
        sortOption = option
        selections = option.sorted(selections)
        if option.needsTrackCounts { requestAllTrackCounts() }
    }

    // MARK: - Track counts

    /// Called as a row becomes visible.
    func requestTrackCount(for id: String) {
        guard let key = countCacheKeys[id],
              cachedCounts[key] == nil,
              !attemptedCounts.contains(id),
              activeCountTasks[id] == nil,
              !countQueue.contains(id)
        else { return }
        countQueue.append(id)
        startQueuedCounts()
    }

    private func requestAllTrackCounts() {
        selections.forEach { requestTrackCount(for: $0.id) }
    }

    /// Frees MusicKit for the Session Setup screen.
    func setCountingPaused(_ paused: Bool) {
        guard paused != isCountingPaused else { return }
        isCountingPaused = paused

        if paused {
            for (id, task) in activeCountTasks {
                task.cancel()
                attemptedCounts.remove(id)
                countQueue.insert(id, at: 0)
            }
            activeCountTasks = [:]
        } else {
            startQueuedCounts()
        }
    }

    private func startQueuedCounts() {
        guard !isCountingPaused else { return }

        while activeCountTasks.count < maxConcurrentCounts, !countQueue.isEmpty {
            let id = countQueue.removeFirst()
            guard let playlist = playlistsByID[id] else { continue }
            attemptedCounts.insert(id)
            activeCountTasks[id] = Task { [weak self] in
                let count = try? await AppleMusicTracks.all(in: playlist).count
                guard !Task.isCancelled else { return }
                self?.finishCount(id: id, count: count)
            }
        }
    }

    private func finishCount(id: String, count: Int?) {
        activeCountTasks[id] = nil
        if let count {
            pendingCounts[id] = count
            scheduleCountFlush()
        }
        startQueuedCounts()
    }

    /// Applies finished counts together so Home redraws at most twice a second.
    private func scheduleCountFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushCounts()
        }
    }

    private func flushCounts() {
        flushTask = nil
        guard !pendingCounts.isEmpty else { return }

        var rows = selections
        for index in rows.indices {
            let id = rows[index].id
            guard let count = pendingCounts[id] else { continue }
            rows[index].trackCount = count
            if let key = countCacheKeys[id] { cachedCounts[key] = count }
        }
        pendingCounts = [:]
        saveCounts()
        selections = sortOption.needsTrackCounts ? sortOption.sorted(rows) : rows
    }

    private func cancelCountWork() {
        activeCountTasks.values.forEach { $0.cancel() }
        activeCountTasks = [:]
        countQueue = []
        pendingCounts = [:]
        flushTask?.cancel()
        flushTask = nil
    }

    private func saveCounts() {
        UserDefaults.standard.set(cachedCounts, forKey: countsKey)
    }
}
