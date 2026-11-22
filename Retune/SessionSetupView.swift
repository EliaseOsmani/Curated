//
//  SessionSetupView.swift
//  Retune
//

import SwiftUI
import MusicKit
import Combine
import SwiftData

// MARK: - Order Mode

enum SessionOrderMode: String, CaseIterable {
    case inOrder  = "Playlist Order"
    case shuffled = "Shuffle"

    var icon: String {
        switch self {
        case .inOrder:  return "list.number"
        case .shuffled: return "shuffle"
        }
    }
}

// MARK: - Setup VM

@MainActor
final class SessionSetupVM: ObservableObject {
    @Published var songs: [Song] = []
    @Published private(set) var shuffledSongs: [Song] = []
    @Published var isLoading = true
    @Published var loadedSongCount = 0
    @Published var errorMessage: String?
    @Published private(set) var orderMode: SessionOrderMode = .inOrder

    let playlist: Playlist
    private var hasLoaded = false

    init(playlist: Playlist) {
        self.playlist = playlist
    }

    // Load songs eagerly in the background while the user reads the setup screen.
    // Runs once: Song IDs and the shuffled order must survive returning here.
    func loadSongs() async {
        guard !hasLoaded else { return }
        isLoading = true
        loadedSongCount = 0
        errorMessage = nil
        defer { isLoading = false }

        do {
            let tracks = try await AppleMusicTracks.all(in: playlist) { [weak self] count in
                self?.loadedSongCount = count
            }

            let mkSongs: [MusicKit.Song] = tracks.compactMap { track in
                guard case let .song(song) = track else { return nil }
                return song
            }
            songs = mkSongs.map {
                Song(
                    title: $0.title,
                    artist: $0.artistName,
                    artworkURL: $0.artwork?.url(width: 600, height: 600),
                    previewURL: $0.previewAssets?.first?.url,
                    musicItemID: $0.id.rawValue
                )
            }
            if orderMode == .shuffled { shuffledSongs = songs.shuffled() }
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Selecting Shuffle while it's already selected makes a new order.
    func select(_ mode: SessionOrderMode) {
        if mode == .shuffled, orderMode == .shuffled || shuffledSongs.isEmpty {
            shuffledSongs = songs.shuffled()
        }
        orderMode = mode
    }

    /// The exact order shown on screen and used for the session.
    var orderedSongs: [Song] {
        orderMode == .shuffled ? shuffledSongs : songs
    }
}

// MARK: - Session Setup View

struct SessionSetupView: View {
    let playlist: Playlist

    @StateObject private var vm: SessionSetupVM
    @Environment(\.modelContext) private var modelContext
    @Query private var savedSessions: [SessionRecord]

    @State private var navigateToSession = false
    @State private var sessionSongs: [Song] = []
    @State private var sessionOrderMode = SessionOrderMode.inOrder.rawValue
    @State private var showStartOverConfirmation = false
    @State private var artworkImage: UIImage? = nil
    @State private var tintColor: Color = .purple

    init(playlist: Playlist) {
        self.playlist = playlist
        _vm = StateObject(wrappedValue: SessionSetupVM(playlist: playlist))
        let playlistID = playlist.id.rawValue
        _savedSessions = Query(filter: #Predicate<SessionRecord> { $0.playlistID == playlistID })
    }

    private var existingSession: SessionRecord? { savedSessions.first }
    private var canStart: Bool { !vm.isLoading && !vm.songs.isEmpty }

    var body: some View {
        ZStack {
            // Subtle tinted background
            tintColor
                .opacity(0.12)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: tintColor)

            Color(.systemBackground)
                .opacity(0.85)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    artworkHeader
                    songCountBadge
                    orderPicker
                    songList
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
        }
        .navigationTitle("Session Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Songs shouldn't wait for the cover image.
            async let artwork: Void = loadArtwork()
            await vm.loadSongs()
            await artwork
        }
        .navigationDestination(isPresented: $navigateToSession) {
            RetuneSwipeView(
                songs: sessionSongs,
                playlistID: playlist.id.rawValue,
                playlistName: playlist.name,
                orderMode: sessionOrderMode
            )
        }
        .confirmationDialog(
            "Start over?",
            isPresented: $showStartOverConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Progress and Start Over", role: .destructive) { startOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your saved swipes for this playlist will be permanently removed.")
        }
    }

    // MARK: - Session actions

    private func startNewSession() {
        sessionSongs = vm.orderedSongs
        sessionOrderMode = vm.orderMode.rawValue
        navigateToSession = true
    }

    private func resume(_ session: SessionRecord) {
        sessionSongs = session.allSongs
        sessionOrderMode = session.orderMode
        navigateToSession = true
    }

    private func startOver() {
        savedSessions.forEach { modelContext.delete($0) }
        try? modelContext.save()
        startNewSession()
    }

    // MARK: - Artwork Header

    private var artworkHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(tintColor.opacity(0.15))
                    .frame(width: 160, height: 160)

                if let img = artworkImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 48))
                        .foregroundStyle(tintColor)
                }
            }
            .shadow(color: tintColor.opacity(0.35), radius: 20, y: 8)

            VStack(spacing: 4) {
                Text(playlist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Apple Music")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Song Count Badge

    private var songCountBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(tintColor)

            if vm.isLoading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.8)
                    Text(vm.loadedSongCount > 0 ? "Loading songs… \(vm.loadedSongCount)" : "Loading songs…")
                        .foregroundStyle(.secondary)
                }
            } else if let err = vm.errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Text("\(vm.songs.count) songs")
                    .font(.body.weight(.medium))
            }
        }
        .font(.body)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
    }

    // MARK: - Order Picker

    private var orderPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Play Order")
                .font(.headline)
                .padding(.horizontal, 4)

            HStack(spacing: 12) {
                ForEach(SessionOrderMode.allCases, id: \.self) { mode in
                    orderOption(mode)
                }
            }
        }
    }

    private func orderOption(_ mode: SessionOrderMode) -> some View {
        let isSelected = vm.orderMode == mode

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                vm.select(mode)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.body.weight(.medium))
                Text(mode.rawValue)
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? tintColor : Color(.secondarySystemBackground))
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? tintColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Song List

    @ViewBuilder
    private var songList: some View {
        if !vm.orderedSongs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Songs")
                        .font(.headline)
                    Text(songListCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                LazyVStack(spacing: 0) {
                    ForEach(Array(vm.orderedSongs.enumerated()), id: \.element.id) { index, song in
                        SetupSongRow(position: index + 1, song: song)
                        if index < vm.orderedSongs.count - 1 {
                            Divider().padding(.leading, 84)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .transaction { $0.animation = nil }
            }
        }
    }

    private var songListCaption: String {
        if existingSession != nil {
            return "Start Over uses this order. Resume keeps your saved order."
        }
        return vm.orderMode == .shuffled
            ? "Shuffled order. Tap Shuffle again to reshuffle."
            : "Playlist order"
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        if let session = existingSession {
            VStack(spacing: 8) {
                Button {
                    resume(session)
                } label: {
                    primaryLabel(title: "Resume Session", icon: "arrow.counterclockwise")
                        .background(tintColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                Button("Start Over", role: .destructive) {
                    showStartOverConfirmation = true
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 32)
                .disabled(!canStart)
            }
        } else {
            startButton
        }
    }

    private func primaryLabel(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            startNewSession()
        } label: {
            HStack(spacing: 10) {
                if vm.isLoading {
                    ProgressView().tint(.white)
                    Text("Loading…")
                } else {
                    Image(systemName: "play.fill")
                    Text("Start Retuning")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(canStart ? tintColor : Color(.systemFill))
            .foregroundStyle(canStart ? .white : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(!canStart)
        .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
    }

    // MARK: - Artwork loader

    private func loadArtwork() async {
        guard let url = playlist.artwork?.url(width: 320, height: 320) else { return }
        if let cached = ImageCache.shared.image(for: url) {
            artworkImage = cached
            if let avg = await cached.averageColorInBackground { tintColor = Color(uiColor: avg) }
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return }
        ImageCache.shared.set(img, for: url)
        artworkImage = img
        if let avg = await img.averageColorInBackground { tintColor = Color(uiColor: avg) }
    }
}

// MARK: - Song Row

private struct SetupSongRow: View {
    let position: Int
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)

            SongThumbnail(url: song.artworkURL)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Thumbnail

/// Decodes a small copy off the main thread so long song lists scroll smoothly.
private struct SongThumbnail: View {
    let url: URL?

    private static let cache = NSCache<NSURL, UIImage>()

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        image = nil
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let thumbnail = await Task.detached(priority: .utility) {
            Self.downsample(data)
        }.value
        guard !Task.isCancelled, let thumbnail else { return }
        Self.cache.setObject(thumbnail, forKey: url as NSURL)
        image = thumbnail
    }

    private nonisolated static func downsample(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 120
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
