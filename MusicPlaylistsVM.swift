//
//  MusicPlaylistsVM.swift
//  Retune
//
//  Created by Eliase Osmani on 2/17/26.
//

import Foundation
import Combine
import MusicKit

@MainActor
final class MusicPlaylistsVM: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            errorMessage = "Apple Music access not authorized."
            return
        }

        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 50
            let response = try await request.response()
            let libraryPlaylists = Array(response.items)

            // Playlist duration isn't exposed by MusicKit. Load track
            // relationships so Home can sort reliably by playlist length.
            playlists = await withTaskGroup(of: (Int, Playlist).self) { group in
                for (index, playlist) in libraryPlaylists.enumerated() {
                    group.addTask {
                        let detailed = (try? await playlist.with([.tracks])) ?? playlist
                        return (index, detailed)
                    }
                }

                var results = Array<Playlist?>(repeating: nil, count: libraryPlaylists.count)
                for await (index, playlist) in group {
                    results[index] = playlist
                }
                return results.enumerated().map { index, playlist in
                    playlist ?? libraryPlaylists[index]
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
