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
    /// Reading Apple Music's copy back to confirm every song stuck.
    case verifying
    case success(playlistName: String)
    case partialSuccess(playlistName: String, added: Int, total: Int, missed: [MissedSong])
    /// No kept song could be added.
    case nothingSaved(missed: [MissedSong])
    case noSubscription
    case notAuthorized
    case failed(String)
}

// MARK: - SavePlaylistVM

@MainActor
final class SavePlaylistVM: ObservableObject {
    @Published var saveState: SaveState = .idle

    /// Created by an attempt that added no songs. The API can't delete
    /// playlists, so a retry fills this one instead of leaving an empty copy.
    @Published private(set) var retryPlaylistID: String?

    var isWorking: Bool {
        switch saveState {
        case .idle, .success, .partialSuccess, .nothingSaved, .noSubscription, .notAuthorized, .failed: return false
        default: return true
        }
    }

    /// `sourcePlaylistID` is the playlist the session came from. Its tracks
    /// name the catalog version of songs that aren't in the library.
    func saveToAppleMusic(name: String, keptSongs: [Song], sourcePlaylistID: String? = nil) async {
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
        let resolutions = await AppleMusicSaveResolver.resolve(keptSongs, sourcePlaylistID: sourcePlaylistID)

        var toAdd: [(song: Song, track: AppleMusicLibraryAPI.Track)] = []
        var missed: [MissedSong] = []
        for song in keptSongs {
            switch resolutions[AppleMusicSaveResolver.key(for: song)] {
            case .add(let track)?: toAdd.append((song, track))
            case .missing(let reason)?: missed.append(MissedSong(song: song, reason: reason))
            case nil: missed.append(MissedSong(song: song, reason: .lookupFailed))
            }
        }

        guard !toAdd.isEmpty else {
            saveState = .nothingSaved(missed: missed)
            return
        }

        saveState = .creatingPlaylist
        let playlistID: String
        if let retryPlaylistID {
            playlistID = retryPlaylistID
        } else {
            do {
                playlistID = try await AppleMusicLibraryAPI.createPlaylist(
                    name: name,
                    description: "Curated with Retune on \(Date().formatted(date: .abbreviated, time: .omitted))"
                )
                retryPlaylistID = playlistID
                NSLog("[Retune] Save: created playlist %@", playlistID)
            } catch {
                saveState = Self.state(for: AppleMusicLibraryAPI.classify(error))
                return
            }
        }

        // Batches keep the request count low. If one is refused, its songs
        // are retried one by one so a single bad song doesn't sink the rest.
        var addedCount = 0
        var processed = 0
        for batch in toAdd.chunked(into: 100) {
            saveState = .addingTracks(current: processed, total: toAdd.count)
            do {
                try await AppleMusicLibraryAPI.add(batch.map(\.track), to: playlistID)
                addedCount += batch.count
            } catch {
                if case .transient = AppleMusicLibraryAPI.classify(error) {
                    missed += batch.map { MissedSong(song: $0.song, reason: .addFailed) }
                } else {
                    for entry in batch {
                        do {
                            try await AppleMusicLibraryAPI.add([entry.track], to: playlistID)
                            addedCount += 1
                        } catch {
                            missed.append(MissedSong(song: entry.song, reason: Self.reason(for: error, track: entry.track)))
                        }
                    }
                }
            }
            processed += batch.count
        }
        saveState = .addingTracks(current: processed, total: toAdd.count)
        if addedCount > 0 {
            retryPlaylistID = nil
            AppStateManager.shared.playlistSaved(id: playlistID, name: name)
        }
        NSLog("[Retune] Save: added %d of %d kept songs", addedCount, keptSongs.count)

        // Check Apple Music's own copy of the playlist, so a song that was
        // accepted but not stored is reported instead of counted as saved.
        if addedCount > 0 {
            saveState = .verifying
            let added = toAdd.filter { entry in !missed.contains { $0.song.id == entry.song.id } }
            let dropped = await Self.confirmSaved(added, playlistID: playlistID)
            if !dropped.isEmpty {
                missed += dropped
                addedCount -= dropped.count
            }
        }

        // Same order as the review list.
        let order = Dictionary(keptSongs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        missed.sort { (order[$0.song.id] ?? 0) < (order[$1.song.id] ?? 0) }

        if addedCount == keptSongs.count {
            saveState = .success(playlistName: name)
        } else if addedCount == 0 {
            saveState = .nothingSaved(missed: missed)
        } else {
            saveState = .partialSuccess(playlistName: name, added: addedCount, total: keptSongs.count, missed: missed)
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

    /// Returns the songs still missing from Apple Music's copy of the
    /// playlist after waiting and retrying, with the reason for each.
    ///
    /// Apple's servers can take a few seconds to show a song that was just
    /// added, so the playlist is read again over about 12 seconds first.
    /// A song still missing after that was refused. Apple can silently drop a
    /// track and then reject it outright on a re-add, so the retry uses the
    /// song's catalog version, and only falls back to the original track.
    private static func confirmSaved(
        _ entries: [(song: Song, track: AppleMusicLibraryAPI.Track)],
        playlistID: String
    ) async -> [MissedSong] {
        let songs = entries.map(\.song)
        guard var missing = await songsMissingOnServer(playlistID: playlistID, expected: songs) else { return [] }

        for delay in [2, 4, 6] where !missing.isEmpty {
            try? await Task.sleep(for: .seconds(delay))
            guard let recheck = await songsMissingOnServer(playlistID: playlistID, expected: songs) else { return [] }
            missing = recheck
        }
        guard !missing.isEmpty else { return [] }

        let missingIDs = Set(missing.map(\.id))
        let retries = entries.filter { missingIDs.contains($0.song.id) }
        var stillMissing: [MissedSong] = []

        for entry in retries {
            NSLog("[Retune] Save: \"%@\" (%@ %@) wasn't kept; retrying",
                  entry.song.title, entry.track.type, entry.track.id)
            var candidates: [AppleMusicLibraryAPI.Track] = []
            if let alternate = await AppleMusicSaveResolver.alternateTrack(for: entry.song, excluding: entry.track) {
                candidates.append(alternate)
            }
            candidates.append(entry.track)

            var added = false
            for track in candidates {
                do {
                    try await AppleMusicLibraryAPI.add([track], to: playlistID)
                    NSLog("[Retune] Save: re-added \"%@\" as %@ %@", entry.song.title, track.type, track.id)
                    added = true
                    break
                } catch {
                    NSLog("[Retune] Save: re-add as %@ %@ failed: %@", track.type, track.id, String(describing: error))
                }
            }
            if !added {
                stillMissing.append(MissedSong(
                    song: entry.song,
                    reason: entry.track.isLibraryOnly && candidates.count == 1 ? .libraryOnlyRejected : .notKept
                ))
            }
        }

        // Only the retried songs can have changed, so recheck just those.
        let addedBack = retries.map(\.song).filter { song in !stillMissing.contains { $0.song.id == song.id } }
        guard !addedBack.isEmpty else { return stillMissing }
        try? await Task.sleep(for: .seconds(3))
        if let after = await songsMissingOnServer(playlistID: playlistID, expected: songs) {
            let afterIDs = Set(after.map(\.id))
            for song in addedBack where afterIDs.contains(song.id) {
                stillMissing.append(MissedSong(song: song, reason: .notKept))
            }
        }
        return stillMissing
    }

    /// Expected songs missing from Apple Music's copy of the playlist, or nil
    /// if it couldn't be read. Song IDs differ in the library, so songs are
    /// matched by title and artist, counting repeats.
    private static func songsMissingOnServer(playlistID: String, expected: [Song]) async -> [Song]? {
        do {
            let names = try await AppleMusicLibraryAPI.trackNames(in: playlistID)
            NSLog("[Retune] Save: Apple Music's copy of the playlist has %d of %d added songs", names.count, expected.count)
            guard names.count < expected.count else { return [] }

            func key(_ title: String, _ artist: String) -> String {
                "\(title)|\(artist)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            }
            var remaining: [String: Int] = [:]
            for name in names { remaining[key(name.title, name.artist), default: 0] += 1 }

            var missing: [Song] = []
            for song in expected {
                let songKey = key(song.title, song.artist)
                if let count = remaining[songKey], count > 0 {
                    remaining[songKey] = count - 1
                } else {
                    missing.append(song)
                }
            }
            // Titles can differ between the library and the catalog. Never
            // report more songs missing than the count shows.
            return Array(missing.prefix(expected.count - names.count))
        } catch {
            NSLog("[Retune] Save: couldn't read Apple Music's copy of the playlist: %@", String(describing: error))
            return nil
        }
    }

    private static func state(for failure: AppleMusicLibraryAPI.Failure) -> SaveState {
        switch failure {
        case .transient:
            return .failed("Apple Music didn't respond. Check your connection and try again.")
        case .notAuthorized:
            return .notAuthorized
        case .noSubscription:
            return .noSubscription
        case .account(let message):
            return .failed(message)
        case .rejected(let detail):
            let base = "Apple Music couldn't create the playlist."
            guard let detail, !detail.isEmpty else { return .failed(base) }
            return .failed("\(base) (\(detail))")
        }
    }

    private static func reason(for error: Error, track: AppleMusicLibraryAPI.Track) -> MissedSong.Reason {
        switch AppleMusicLibraryAPI.classify(error) {
        case .transient:
            return .addFailed
        case .rejected(let detail):
            return track.isLibraryOnly ? .libraryOnlyRejected : .rejected(detail: detail)
        case .notAuthorized, .noSubscription, .account:
            return track.isLibraryOnly ? .libraryOnlyRejected : .rejected(detail: nil)
        }
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
    let sourcePlaylistID: String?

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
        sourcePlaylistID: String? = nil,
        onSaveSucceeded: @escaping () -> Void = {},
        onReviewChanged: @escaping ([Song], [Song]) -> Void = { _, _ in }
    ) {
        self.keptSongs = keptSongs
        self.removedSongs = removedSongs
        self.platform = platform
        self.originalSongs = originalSongs ?? (keptSongs + removedSongs)
        self.sourcePlaylistID = sourcePlaylistID
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

            if !missedSongs.isEmpty {
                Section {
                    ForEach(missedSongs) { missedSongRow($0) }
                } header: {
                    Text("Not Saved · \(missedSongs.count)")
                }
            }

            if !vm.isWorking {
                Section {
                    if isFinalState {
                        Button("Back to Home") { AppStateManager.shared.returnHome() }
                    } else {
                        Button("Back to Summary") { dismiss() }
                    }
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
                    .disabled(vm.isWorking || vm.retryPlaylistID != nil)
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
                        await vm.saveToAppleMusic(
                            name: newName,
                            keptSongs: reviewedKeptSongs,
                            sourcePlaylistID: sourcePlaylistID
                        )
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

        case .verifying:
            progressRow(label: "Checking the saved playlist…", icon: "checkmark.circle")

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
                    Text("Songs can take a minute to appear on this device while Apple Music syncs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

        case .partialSuccess(let name, let added, let total, let missed):
            VStack(alignment: .leading, spacing: 6) {
                Label("Partially saved", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))
                Text("\"\(name)\" was created with \(added) of \(total) songs. \(missed.count == 1 ? "1 song couldn't" : "\(missed.count) songs couldn't") be added. See below for why. Your Retune session has been kept so you can review it.")
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

        case .nothingSaved(let missed):
            VStack(alignment: .leading, spacing: 6) {
                Label("Nothing saved", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.body.weight(.medium))
                Text(missed.count == 1
                     ? "The kept song couldn't be added. See below for why."
                     : "None of the \(missed.count) kept songs could be added. See below for why.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") { vm.saveState = .idle }
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

    private var missedSongs: [MissedSong] {
        switch vm.saveState {
        case .partialSuccess(_, _, _, let missed), .nothingSaved(let missed): return missed
        default: return []
        }
    }

    private func missedSongRow(_ missed: MissedSong) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(missed.song.title)
                .font(.body)
                .lineLimit(1)
            Text(missed.song.artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(missed.explanation)
                .font(.caption)
                .foregroundStyle(missed.isRetryable ? Color.orange : Color.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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
