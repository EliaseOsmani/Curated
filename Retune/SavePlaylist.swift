//
//  SavePlaylist.swift
//  Retune
//

import SwiftUI
import MusicKit
import Combine

// MARK: - Save State

enum SaveState: Equatable {
    case idle
    case checkingSubscription
    case lookingUpTracks
    case creatingPlaylist
    case addingTracks(current: Int, total: Int)
    case success(playlistName: String)
    case partialSuccess(playlistName: String, added: Int, total: Int)
    case noSubscription
    case notAuthorized
    case failed(String)
}

// MARK: - SavePlaylistVM

@MainActor
final class SavePlaylistVM: ObservableObject {
    @Published var saveState: SaveState = .idle

    /// Created by a failed attempt that added no songs. MusicKit can't delete
    /// playlists, so a retry fills this one instead of leaving an empty copy.
    @Published private(set) var emptyPlaylist: Playlist?

    var isWorking: Bool {
        switch saveState {
        case .idle, .success, .partialSuccess, .noSubscription, .notAuthorized, .failed: return false
        default: return true
        }
    }

    func saveToAppleMusic(name: String, keptSongs: [Song]) async {
        guard !isWorking else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !keptSongs.isEmpty else {
            saveState = .failed("No songs to save — keep at least one song before saving.")
            return
        }

        saveState = .checkingSubscription
        // Only prompt when the user hasn't decided. Asking again can stall on
        // Apple's account daemon.
        let currentStatus = MusicAuthorization.currentStatus
        let status = currentStatus == .notDetermined
            ? await MusicAuthorization.request()
            : currentStatus
        guard status == .authorized else {
            saveState = .notAuthorized
            return
        }

        saveState = .lookingUpTracks
        guard keptSongs.contains(where: { $0.musicItemID != nil }) else {
            saveState = .failed("None of the kept songs have Apple Music IDs.")
            return
        }

        let resolvedItems: [any MusicPlaylistAddable]
        do {
            resolvedItems = try await resolveItems(for: keptSongs)
        } catch {
            saveState = handleMusicKitError(error, fallback: "Couldn't look up songs in Apple Music.")
            return
        }

        guard !resolvedItems.isEmpty else {
            saveState = .failed("Couldn't find any of the kept songs in Apple Music.")
            return
        }

        saveState = .creatingPlaylist
        let destination: Playlist
        if let emptyPlaylist {
            destination = emptyPlaylist
        } else {
            do {
                destination = try await MusicLibrary.shared.createPlaylist(
                    name: name,
                    description: "Curated with Retune on \(Date().formatted(date: .abbreviated, time: .omitted))",
                    authorDisplayName: nil
                )
                emptyPlaylist = destination
            } catch {
                saveState = handleMusicKitError(error, fallback: "Couldn't create playlist in Apple Music.")
                return
            }
        }

        var addedCount = 0
        var firstAddError: Error?
        for (index, item) in resolvedItems.enumerated() {
            saveState = .addingTracks(current: index + 1, total: resolvedItems.count)
            do {
                try await MusicLibrary.shared.add(item, to: destination)
                addedCount += 1
            } catch {
                firstAddError = firstAddError ?? error
                print("[Retune] Couldn't add track \(index + 1): \(error)")
            }
        }
        if addedCount > 0 { emptyPlaylist = nil }

        let expectedCount = keptSongs.count
        if addedCount == expectedCount {
            saveState = .success(playlistName: name)
        } else if addedCount == 0 {
            if let firstAddError {
                saveState = handleMusicKitError(
                    firstAddError,
                    fallback: "Playlist was created but no songs could be added. Try again."
                )
            } else {
                saveState = .failed("Playlist was created but no songs could be added. Try again.")
            }
        } else {
            saveState = .partialSuccess(playlistName: name, added: addedCount, total: expectedCount)
        }
    }

    func saveToSpotify(name: String, keptSongs: [Song]) async {
        guard !isWorking else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !keptSongs.isEmpty else {
            saveState = .failed("No songs to save — keep at least one song before saving.")
            return
        }

        saveState = .creatingPlaylist
        do {
            saveState = .addingTracks(current: 0, total: keptSongs.count)
            let _ = try await SpotifyAPIClient.shared.savePlaylist(name: name, keptSongs: keptSongs)
            saveState = .success(playlistName: name)
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    /// Songs from a library playlist carry library IDs ("i.…"), which the
    /// catalog doesn't recognize. Resolve each ID from the right source and
    /// return the items in the original order, keeping repeated tracks.
    private func resolveItems(for songs: [Song]) async throws -> [any MusicPlaylistAddable] {
        let videoIDs = songs.filter { $0.isMusicVideo == true }.compactMap(\.musicItemID).map { MusicItemID($0) }
        let songIDs = songs.filter { $0.isMusicVideo != true }.compactMap(\.musicItemID).map { MusicItemID($0) }

        var itemsByID: [MusicItemID: any MusicPlaylistAddable] = [:]
        for song in try await fetchSongs(ids: songIDs) { itemsByID[song.id] = song }
        for video in try await fetchMusicVideos(ids: videoIDs) { itemsByID[video.id] = video }

        return songs.compactMap { song in
            song.musicItemID.flatMap { itemsByID[MusicItemID($0)] }
        }
    }

    private func fetchSongs(ids: [MusicItemID]) async throws -> [MusicKit.Song] {
        let uniqueIDs = Array(Set(ids))
        let libraryIDs = uniqueIDs.filter { $0.rawValue.hasPrefix("i.") }
        let catalogIDs = uniqueIDs.filter { !$0.rawValue.hasPrefix("i.") }
        let batchSize = 25
        var results: [MusicKit.Song] = []

        for batchStart in stride(from: 0, to: libraryIDs.count, by: batchSize) {
            let batch = Array(libraryIDs[batchStart..<min(batchStart + batchSize, libraryIDs.count)])
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.filter(matching: \.id, memberOf: batch)
            request.limit = batchSize
            results.append(contentsOf: try await request.response().items)
        }

        for batchStart in stride(from: 0, to: catalogIDs.count, by: batchSize) {
            let batch = Array(catalogIDs[batchStart..<min(batchStart + batchSize, catalogIDs.count)])
            var request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, memberOf: batch)
            request.limit = batchSize
            results.append(contentsOf: try await request.response().items)
        }
        return results
    }

    private func fetchMusicVideos(ids: [MusicItemID]) async throws -> [MusicVideo] {
        let uniqueIDs = Array(Set(ids))
        let libraryIDs = uniqueIDs.filter { $0.rawValue.hasPrefix("i.") }
        let catalogIDs = uniqueIDs.filter { !$0.rawValue.hasPrefix("i.") }
        let batchSize = 25
        var results: [MusicVideo] = []

        for batchStart in stride(from: 0, to: libraryIDs.count, by: batchSize) {
            let batch = Array(libraryIDs[batchStart..<min(batchStart + batchSize, libraryIDs.count)])
            var request = MusicLibraryRequest<MusicVideo>()
            request.filter(matching: \.id, memberOf: batch)
            request.limit = batchSize
            results.append(contentsOf: try await request.response().items)
        }

        for batchStart in stride(from: 0, to: catalogIDs.count, by: batchSize) {
            let batch = Array(catalogIDs[batchStart..<min(batchStart + batchSize, catalogIDs.count)])
            var request = MusicCatalogResourceRequest<MusicVideo>(matching: \.id, memberOf: batch)
            request.limit = batchSize
            results.append(contentsOf: try await request.response().items)
        }
        return results
    }

    private func handleMusicKitError(_ error: Error, fallback: String) -> SaveState {
        let nsError = error as NSError
        if nsError.domain == "MPErrorDomain" && nsError.code == 5 {
            return .noSubscription
        }
        return .failed(nsError.localizedDescription.isEmpty ? fallback : nsError.localizedDescription)
    }
}

// MARK: - SaveRetunedPlaylistView

struct SaveRetunedPlaylistView: View {
    let keptSongs:    [Song]
    let removedSongs: [Song]
    let platform:     String
    let onSaveSucceeded: () -> Void
    let onReviewChanged: ([Song], [Song]) -> Void
    let originalSongs: [Song]

    @StateObject private var vm = SavePlaylistVM()
    @State private var newName = ""
    @State private var reviewedKeptSongs: [Song]
    @State private var reviewedRemovedSongs: [Song]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(
        keptSongs: [Song],
        removedSongs: [Song],
        platform: String,
        originalSongs: [Song]? = nil,
        onSaveSucceeded: @escaping () -> Void = {},
        onReviewChanged: @escaping ([Song], [Song]) -> Void = { _, _ in }
    ) {
        self.keptSongs = keptSongs
        self.removedSongs = removedSongs
        self.platform = platform
        self.originalSongs = originalSongs ?? (keptSongs + removedSongs)
        self.onSaveSucceeded = onSaveSucceeded
        self.onReviewChanged = onReviewChanged
        _reviewedKeptSongs = State(initialValue: keptSongs)
        _reviewedRemovedSongs = State(initialValue: removedSongs)
    }

    var body: some View {
        Form {
            Section("Session Summary") {
                HStack {
                    Label("\(reviewedKeptSongs.count) kept", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Label("\(reviewedRemovedSongs.count) archived", systemImage: "archivebox.fill")
                        .foregroundStyle(.secondary)
                }
            }

            if !isFinalState && !vm.isWorking {
                Section {
                    ForEach(reviewedKeptSongs) { song in
                        reviewRow(song: song, isKept: true)
                    }
                } header: {
                    Text("Keep · \(reviewedKeptSongs.count)")
                } footer: {
                    Text("Tap the archive button to move a song out of the new playlist.")
                }

                Section {
                    ForEach(reviewedRemovedSongs) { song in
                        reviewRow(song: song, isKept: false)
                    }
                } header: {
                    Text("Archived · \(reviewedRemovedSongs.count)")
                } footer: {
                    Text("Tap the restore button to put a song back into the new playlist.")
                }
            }

            if !vm.isWorking {
                Section {
                    Button("Back to Summary") { dismiss() }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { saveBar }
        .navigationTitle("Save Playlist")
        .navigationBarTitleDisplayMode(.inline)
        // Leaving mid-save would allow a second save and a duplicate playlist.
        .navigationBarBackButtonHidden(vm.isWorking)
        .onAppear {
            if newName.isEmpty {
                newName = "Retuned • \(Date().formatted(date: .abbreviated, time: .omitted))"
            }
        }
    }

    // MARK: - Pinned save bar

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isFinalState {
                TextField("Playlist name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    // A retry fills the playlist already created under this name.
                    .disabled(vm.isWorking || vm.emptyPlaylist != nil)
                    .accessibilityLabel("New playlist name")
            }

            saveStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch vm.saveState {
        case .idle:
            Button {
                Task {
                    if platform == "spotify" {
                        await vm.saveToSpotify(name: newName, keptSongs: reviewedKeptSongs)
                    } else {
                        await vm.saveToAppleMusic(name: newName, keptSongs: reviewedKeptSongs)
                    }
                    if case .success = vm.saveState {
                        onSaveSucceeded()
                    }
                }
            } label: {
                Label(
                    "Save to \(platform == "spotify" ? "Spotify" : "Apple Music")",
                    systemImage: "music.note.list"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        case .checkingSubscription:
            progressRow(label: "Checking Apple Music…", icon: "music.note")

        case .lookingUpTracks:
            progressRow(label: "Looking up tracks…", icon: "magnifyingglass")

        case .creatingPlaylist:
            progressRow(label: "Creating playlist…", icon: "plus.circle")

        case .addingTracks(let current, let total):
            VStack(alignment: .leading, spacing: 8) {
                progressRow(label: "Adding tracks (\(current) of \(total))…", icon: "music.note.list")
                ProgressView(value: Double(current), total: Double(total))
                    .tint(.green)
            }

        case .success(let name):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved!")
                        .font(.body.weight(.medium))
                    Text("\"\(name)\" · \(reviewedKeptSongs.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

        case .partialSuccess(let name, let added, let total):
            VStack(alignment: .leading, spacing: 6) {
                Label("Partially saved", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))
                Text("\"\(name)\" was created, but only \(added) of \(total) songs were added. Your Retune session has been kept so you can review it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry by creating another playlist") { vm.saveState = .idle }
                    .font(.caption)
            }
            .padding(.vertical, 4)

        case .noSubscription:
            noSubscriptionView

        case .notAuthorized:
            VStack(alignment: .leading, spacing: 6) {
                Label("Apple Music Access Needed", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))
                Text("Allow Retune to access Media & Apple Music in Settings, then try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    Button("Try Again") { vm.saveState = .idle }
                }
                .font(.caption)
            }
            .padding(.vertical, 4)

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label("Save failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.body.weight(.medium))
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") { vm.saveState = .idle }
                    .font(.caption)
            }
            .padding(.vertical, 4)
        }
    }

    private var isFinalState: Bool {
        switch vm.saveState {
        case .success, .partialSuccess, .noSubscription: return true
        default: return false
        }
    }

    private func progressRow(label: String, icon: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.85)
            Label(label, systemImage: icon)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
    }

    private func reviewRow(song: Song, isKept: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .foregroundStyle(isKept ? .green : .secondary)
                .frame(width: 28, height: 28)
                .background((isKept ? Color.green : Color.secondary).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                moveSong(song, toKept: !isKept)
            } label: {
                Image(systemName: isKept ? "archivebox" : "arrow.uturn.backward")
                    .foregroundStyle(isKept ? .red : .green)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isKept ? "Archive \(song.title)" : "Keep \(song.title)")
        }
    }

    private func moveSong(_ song: Song, toKept: Bool) {
        if toKept {
            reviewedRemovedSongs.removeAll { $0.id == song.id }
            reviewedKeptSongs.append(song)
        } else {
            reviewedKeptSongs.removeAll { $0.id == song.id }
            reviewedRemovedSongs.append(song)
        }
        let originalIndex = Dictionary(
            uniqueKeysWithValues: originalSongs.enumerated().map { ($0.element.id, $0.offset) }
        )
        reviewedKeptSongs.sort { originalIndex[$0.id, default: .max] < originalIndex[$1.id, default: .max] }
        reviewedRemovedSongs.sort { originalIndex[$0.id, default: .max] < originalIndex[$1.id, default: .max] }
        onReviewChanged(reviewedKeptSongs, reviewedRemovedSongs)
    }

    private var noSubscriptionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Apple Music Required", systemImage: "music.note")
                .font(.body.weight(.medium))
                .foregroundStyle(.orange)
            Text("Saving playlists requires an active Apple Music subscription.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Learn about Apple Music", destination: URL(string: "https://www.apple.com/apple-music/")!)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
