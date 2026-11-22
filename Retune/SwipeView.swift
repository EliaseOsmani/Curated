//
//  SwipeView.swift
//  Retune
//

import SwiftUI
import SwiftData

// MARK: - Swipe Decision (in-memory, for undo support)

private struct SwipeDecision {
    let song: Song
    let kept: Bool
}

// MARK: - Preview playback key

/// Restarts preview playback when the front card or app visibility changes.
private struct PreviewPlaybackKey: Equatable {
    let songID: UUID?
    let isInBackground: Bool
}

// MARK: - RetuneSwipeView

struct RetuneSwipeView: View {
    let allSongs: [Song]
    let playlistID:   String
    let playlistName: String
    let orderMode:    String

    @State private var remainingSongs: [Song]
    @State private var history:        [SwipeDecision] = []
    @State private var keptSongs:      [Song] = []
    @State private var removedSongs:   [Song] = []
    @State private var goToSave = false
    @State private var showDiscardConfirmation = false
    @State private var sessionWasSaved = false
    @State private var screenTint: Color = .black
    @State private var dragProgress: CGFloat = 0

    // SwiftData
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var sessionRecord: SessionRecord? = nil

    // Preview audio
    @ObservedObject private var audio = AudioPreviewPlayer.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var songIDWithoutPreview: UUID?

    init(songs: [Song], playlistID: String, playlistName: String, orderMode: String) {
        self.allSongs     = songs
        self.playlistID   = playlistID
        self.playlistName = playlistName
        self.orderMode    = orderMode
        _remainingSongs   = State(initialValue: songs)
    }

    private var totalCount:    Int { allSongs.count }
    private var reviewedCount: Int { totalCount - remainingSongs.count }

    var body: some View {
        ZStack {
            screenTint
                .opacity(0.25)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: screenTint)

            Color(.systemBackground)
                .opacity(0.75)
                .ignoresSafeArea()

            SwipeGlow(progress: $dragProgress)

            if remainingSongs.isEmpty {
                sessionCompleteView
            } else {
                VStack(spacing: 0) {
                    progressBar
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    cardStack
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topLeading) { noPreviewLabel }
                        .overlay(alignment: .topTrailing) { muteButton }
                        .padding(.horizontal, 16)

                    undoButton
                        .padding(.bottom, 24)
                }

                SwipeDecisionTag(progress: $dragProgress)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: remainingSongs.first?.id) {
            // Have the next two cards' artwork ready before they're needed.
            for song in remainingSongs.dropFirst().prefix(2) {
                guard !Task.isCancelled else { return }
                await ImageLoader.preload(song.artworkURL)
            }
        }
        .task(id: remainingSongs.first?.id) {
            // Look up upcoming clips so audio starts quickly.
            for song in remainingSongs.dropFirst().prefix(3) {
                guard !Task.isCancelled else { return }
                _ = await previewURL(for: song)
            }
        }
        .task(id: PreviewPlaybackKey(
            songID: remainingSongs.first?.id,
            isInBackground: scenePhase == .background
        )) {
            await playFrontCardPreview()
        }
        .onDisappear { audio.endSession() }
        .navigationDestination(isPresented: $goToSave) {
            SaveRetunedPlaylistView(
                keptSongs: keptSongs,
                removedSongs: removedSongs,
                platform: playlistID.hasPrefix("spotify:") ? "spotify" : "appleMusic",
                originalSongs: allSongs,
                onSaveSucceeded: completeSavedSession,
                onReviewChanged: applyReviewedSongs
            )
        }
        .onAppear { restoreOrCreateSession() }
        .onChange(of: goToSave) { _, isShowingSave in
            if !isShowingSave && sessionWasSaved {
                dismiss()
            }
        }
        .confirmationDialog(
            "Discard this completed session?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Session", role: .destructive) {
                deleteSession()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your swipe decisions will be permanently removed.")
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemFill))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(screenTint.opacity(0.8))
                        .frame(
                            width: totalCount > 0
                                ? geo.size.width * CGFloat(reviewedCount) / CGFloat(totalCount)
                                : 0,
                            height: 6
                        )
                        .animation(.spring(response: 0.4), value: reviewedCount)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(reviewedCount) of \(totalCount)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 12) {
                    Label("\(keptSongs.count)", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.green)
                    Label("\(removedSongs.count)", systemImage: "xmark")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Card Stack

    private var cardStack: some View {
        ZStack {
            if remainingSongs.count > 1 {
                SwipeCard(
                    song: remainingSongs[1],
                    isTopCard: false,
                    onSwipeFinished: { _ in },
                    tintColor: .constant(.gray),
                    dragProgress: .constant(0)
                )
                .id(remainingSongs[1].id)
                .scaleEffect(0.95)
                .offset(y: 14)
                .opacity(0.9)
            }

            let topSong = remainingSongs[0]
            SwipeCard(
                song: topSong,
                isTopCard: true,
                onSwipeFinished: { swipedRight in
                    // Undo can change the top card during the fly-off animation.
                    guard remainingSongs.first?.id == topSong.id else { return }
                    let decided = remainingSongs.removeFirst()
                    history.append(SwipeDecision(song: decided, kept: swipedRight))
                    if swipedRight { keptSongs.append(decided) }
                    else           { removedSongs.append(decided) }
                    persistDecision(song: decided, kept: swipedRight)
                },
                tintColor: $screenTint,
                dragProgress: $dragProgress
            )
            .id(remainingSongs[0].id)
        }
    }

    // MARK: - Preview Audio

    private var muteButton: some View {
        Button {
            audio.toggleMute()
        } label: {
            Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel(audio.isMuted ? "Unmute song previews" : "Mute song previews")
    }

    @ViewBuilder
    private var noPreviewLabel: some View {
        if let front = remainingSongs.first, front.id == songIDWithoutPreview {
            Label("No preview", systemImage: "speaker.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(16)
                .allowsHitTesting(false)
        }
    }

    private func previewURL(for song: Song) async -> URL? {
        // The catalog lookup only applies to Apple Music tracks.
        if playlistID.hasPrefix("spotify:") { return song.previewURL }
        return await PreviewResolver.shared.previewURL(for: song)
    }

    private func playFrontCardPreview() async {
        audio.clear()

        guard scenePhase != .background, let song = remainingSongs.first else {
            audio.endSession()
            return
        }

        let url = await previewURL(for: song)
        guard !Task.isCancelled else { return }

        songIDWithoutPreview = url == nil ? song.id : nil
        if let url {
            audio.play(url: url)
        }
    }

    // MARK: - Undo Button

    private var undoButton: some View {
        Button { undoLastSwipe() } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
        .disabled(history.isEmpty)
        .opacity(history.isEmpty ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.2), value: history.isEmpty)
    }

    // MARK: - Session Complete

    private var sessionCompleteView: some View {
        VStack(spacing: 28) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52))
                .foregroundStyle(screenTint)

            VStack(spacing: 8) {
                Text("Playlist Retuned")
                    .font(.title).fontWeight(.bold)
                Text("Here's your session summary")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            HStack(spacing: 32) {
                statBadge(count: keptSongs.count,    label: "Kept",     color: .green, icon: "checkmark.circle.fill")
                statBadge(count: removedSongs.count, label: "Archived", color: .red,   icon: "archivebox.fill")
            }

            VStack(spacing: 12) {
                Button {
                    goToSave = true
                } label: {
                    Label(
                        playlistID.hasPrefix("spotify:") ? "Save to Spotify" : "Save to Apple Music",
                        systemImage: "music.note.plus"
                    )
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(screenTint.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(role: .destructive) {
                    showDiscardConfirmation = true
                } label: {
                    Text("Discard Session")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemFill))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding(28)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 20)
        .padding(24)
    }

    private func statBadge(count: Int, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text("\(count)").font(.title).fontWeight(.bold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
    }

    // MARK: - Undo Logic

    private func undoLastSwipe() {
        guard let last = history.popLast() else { return }

        if last.kept { keptSongs.removeAll  { $0.id == last.song.id } }
        else         { removedSongs.removeAll { $0.id == last.song.id } }

        remainingSongs.insert(last.song, at: 0)
        undoPersistedDecision(song: last.song)
    }

    // MARK: - SwiftData: Session lifecycle

    /// On appear — either restore an existing session for this playlist, or create a new one.
    private func restoreOrCreateSession() {
        guard !sessionWasSaved else { return }
        let id = playlistID

        // Fetch any existing record for this playlist
        let descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.playlistID == id }
        )
        let existing = (try? modelContext.fetch(descriptor))?.first

        if let record = existing {
            // Restore state from the saved record
            sessionRecord = record
            remainingSongs = record.remainingSongs
            keptSongs      = record.keptSongs
            removedSongs   = record.removedSongs
            // Rebuild in-memory history from decisions (enables undo after resume)
            history = record.decisions
                .sorted { $0.timestamp < $1.timestamp }
                .compactMap { decision in
                    guard let song = record.allSongs.first(where: { $0.id.uuidString == decision.songID })
                    else { return nil }
                    return SwipeDecision(song: song, kept: decision.kept)
                }
        } else {
            let record = SessionRecord(
                playlistID:   playlistID,
                playlistName: playlistName,
                platform:     playlistID.hasPrefix("spotify:") ? "spotify" : "appleMusic",
                orderMode:    orderMode,
                songs:        allSongs
            )
            modelContext.insert(record)
            sessionRecord = record
            saveProgress()
        }
    }

    /// Writes immediately so a crash or force quit can't lose recent swipes.
    private func saveProgress() {
        do {
            try modelContext.save()
        } catch {
            print("[Retune] Couldn't save session progress: \(error)")
        }
    }

    /// Append a decision to the persisted record after every swipe.
    private func persistDecision(song: Song, kept: Bool) {
        guard let record = sessionRecord else { return }
        let decision = SongDecision(songID: song.id.uuidString, kept: kept)
        record.decisions.append(decision)
        saveProgress()
    }

    /// Remove the last decision from the persisted record when undoing.
    private func undoPersistedDecision(song: Song) {
        guard let record = sessionRecord else { return }
        // Remove the most recent decision for this song
        if let toRemove = record.decisions
            .sorted(by: { $0.timestamp > $1.timestamp })
            .first(where: { $0.songID == song.id.uuidString }) {
            record.decisions.removeAll { $0.persistentModelID == toRemove.persistentModelID }
            modelContext.delete(toRemove)
            saveProgress()
        }
    }

    /// Delete the session record when complete or discarded.
    private func deleteSession() {
        guard let record = sessionRecord else { return }
        modelContext.delete(record)
        sessionRecord = nil
        saveProgress()
    }

    /// Remove persisted progress only after the destination playlist fully saves.
    private func completeSavedSession() {
        deleteSession()
        sessionWasSaved = true
    }

    /// Keep pre-save review edits in both the UI and the persisted completed session.
    private func applyReviewedSongs(kept: [Song], removed: [Song]) {
        keptSongs = kept
        removedSongs = removed

        let keptIDs = Set(kept.map { $0.id.uuidString })
        sessionRecord?.decisions.forEach { decision in
            decision.kept = keptIDs.contains(decision.songID)
        }
        saveProgress()
    }
}
