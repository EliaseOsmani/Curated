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

@MainActor
final class MusicPlaylistsVM: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var loadID = UUID()

    func load() async {
        let currentLoadID = UUID()
        loadID = currentLoadID
        isLoading = true
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

            // Show the library response immediately. Track relationships can
            // take much longer to fetch, especially for large libraries.
            playlists = libraryPlaylists
            isLoading = false

            // Playlist duration isn't exposed by MusicKit. Hydrate each
            // playlist independently so track counts and length sorting update
            // progressively without blocking the initial list.
            await withTaskGroup(of: (MusicItemID, Playlist).self) { group in
                for playlist in libraryPlaylists {
                    group.addTask {
                        let detailed = (try? await playlist.with([.tracks])) ?? playlist
                        return (playlist.id, detailed)
                    }
                }

                for await (playlistID, detailedPlaylist) in group {
                    guard loadID == currentLoadID else {
                        group.cancelAll()
                        return
                    }

                    if let index = playlists.firstIndex(where: { $0.id == playlistID }) {
                        playlists[index] = detailedPlaylist
                    }
                }
            }
        } catch {
            guard loadID == currentLoadID else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func fetchLibraryPlaylists() async throws -> [Playlist] {
        try await withThrowingTaskGroup(of: [Playlist].self) { group in
            group.addTask {
                var request = MusicLibraryRequest<Playlist>()
                request.limit = 50
                let response = try await request.response()
                return Array(response.items)
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
}
