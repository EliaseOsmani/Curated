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
    case failed(String)
}

// MARK: - SavePlaylistVM

@MainActor
final class SavePlaylistVM: ObservableObject {
    @Published var saveState: SaveState = .idle

    var isWorking: Bool {
        switch saveState {
        case .idle, .success, .partialSuccess, .noSubscription, .failed: return false
        default: return true
        }
    }

    func saveToAppleMusic(name: String, keptSongs: [Song]) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !keptSongs.isEmpty else {
            saveState = .failed("No songs to save — keep at least one song before saving.")
            return
        }

        saveState = .checkingSubscription
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            saveState = .noSubscription
            return
        }

        saveState = .lookingUpTracks
        let songIDs = keptSongs.compactMap { $0.musicItemID }.map { MusicItemID($0) }
        guard !songIDs.isEmpty else {
            saveState = .failed("None of the kept songs have Apple Music IDs.")
            return
        }

        let resolvedSongs: [MusicKit.Song]
        do {
            resolvedSongs = try await resolveSongs(ids: songIDs)
        } catch {
            saveState = handleMusicKitError(error, fallback: "Couldn't look up songs in Apple Music.")
            return
        }

        guard !resolvedSongs.isEmpty else {
            saveState = .failed("Couldn't find any of the kept songs in Apple Music.")
            return
        }

        saveState = .creatingPlaylist
        let newPlaylist: Playlist
        do {
            newPlaylist = try await MusicLibrary.shared.createPlaylist(
                name: name,
                description: "Curated with Retune on \(Date().formatted(date: .abbreviated, time: .omitted))",
                authorDisplayName: nil
            )
        } catch {
            saveState = handleMusicKitError(error, fallback: "Couldn't create playlist in Apple Music.")
            return
        }

        var addedCount = 0
        var firstAddError: Error?
        for (index, song) in resolvedSongs.enumerated() {
            saveState = .addingTracks(current: index + 1, total: resolvedSongs.count)
            do {
                try await MusicLibrary.shared.add(song, to: newPlaylist)
                addedCount += 1
            } catch {
                firstAddError = firstAddError ?? error
                print("[Retune] Couldn't add \(song.title): \(error)")
            }
        }

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
    /// return the songs in the original order, keeping repeated tracks.
    private func resolveSongs(ids: [MusicItemID]) async throws -> [MusicKit.Song] {
        let uniqueIDs = Array(Set(ids))
        let libraryIDs = uniqueIDs.filter { $0.rawValue.hasPrefix("i.") }
        let catalogIDs = uniqueIDs.filter { !$0.rawValue.hasPrefix("i.") }
        let batchSize = 25
        var songsByID: [MusicItemID: MusicKit.Song] = [:]

        for batchStart in stride(from: 0, to: libraryIDs.count, by: batchSize) {
            let batch = Array(libraryIDs[batchStart..<min(batchStart + batchSize, libraryIDs.count)])
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.filter(matching: \.id, memberOf: batch)
            request.limit = batchSize
            let response = try await request.response()
            response.items.forEach { songsByID[$0.id] = $0 }
        }

        for batchStart in stride(from: 0, to: catalogIDs.count, by: batchSize) {
            let batch = Array(catalogIDs[batchStart..<min(batchStart + batchSize, catalogIDs.count)])
            var request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, memberOf: batch)
            request.limit = batchSize
            let response = try await request.response()
            response.items.forEach { songsByID[$0.id] = $0 }
        }

        return ids.compactMap { songsByID[$0] }
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
                    .disabled(vm.isWorking)
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
