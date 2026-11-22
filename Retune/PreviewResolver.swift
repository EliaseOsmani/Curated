//
//  PreviewResolver.swift
//  Retune
//
//  Finds Apple's preview clip for a song. Library tracks often have no preview
//  assets, so this falls back to the matching Apple Music catalog item.
//

import Foundation
import MusicKit

@MainActor
final class PreviewResolver {
    static let shared = PreviewResolver()

    private var found: [String: URL] = [:]
    private var unavailable: Set<String> = []
    private var inFlight: [String: Task<CatalogPreviewLookup.Outcome, Never>] = [:]

    private init() {}

    /// Lookups are shared and keep running if the caller is cancelled, so a
    /// card that was swiped past still fills the cache.
    func previewURL(for song: Song) async -> URL? {
        if let direct = song.previewURL { return direct }

        // Song.id changes on every fetch, so it can't identify a track here.
        let key = song.musicItemID ?? song.id.uuidString
        if let url = found[key] { return url }
        if unavailable.contains(key) { return nil }

        let task: Task<CatalogPreviewLookup.Outcome, Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let title = song.title
            let artist = song.artist
            let isrc = song.isrc
            let isMusicVideo = song.isMusicVideo == true
            task = Task.detached(priority: .userInitiated) {
                await CatalogPreviewLookup.find(
                    title: title,
                    artist: artist,
                    isrc: isrc,
                    isMusicVideo: isMusicVideo
                )
            }
            inFlight[key] = task
        }

        let outcome = await task.value
        inFlight[key] = nil

        switch outcome {
        case .found(let url):
            found[key] = url
            return url
        case .unavailable:
            unavailable.insert(key)
            return nil
        case .failed:
            // Likely a network problem, so a later attempt may succeed.
            return nil
        }
    }
}

// MARK: - Catalog lookup

nonisolated enum CatalogPreviewLookup {
    enum Outcome: Sendable {
        case found(URL)
        case unavailable
        case failed
    }

    static func find(title: String, artist: String, isrc: String?, isMusicVideo: Bool) async -> Outcome {
        var hadError = false

        // ISRC identifies the exact recording, so try it before a text search.
        if !isMusicVideo, let isrc, !isrc.isEmpty {
            do {
                let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: isrc)
                let items = try await request.response().items
                if let url = items.lazy.compactMap({ $0.previewAssets?.first?.url }).first {
                    return .found(url)
                }
            } catch {
                hadError = true
            }
        }

        do {
            let term = "\(title) \(artist)"
            if isMusicVideo {
                var request = MusicCatalogSearchRequest(term: term, types: [MusicVideo.self])
                request.limit = 10
                let videos = try await request.response().musicVideos
                let match = videos.first {
                    $0.previewAssets?.first?.url != nil
                        && isCloseMatch(title: title, artist: artist, candidateTitle: $0.title, candidateArtist: $0.artistName)
                }
                if let url = match?.previewAssets?.first?.url { return .found(url) }
            } else {
                var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
                request.limit = 10
                let songs = try await request.response().songs
                let match = songs.first {
                    $0.previewAssets?.first?.url != nil
                        && isCloseMatch(title: title, artist: artist, candidateTitle: $0.title, candidateArtist: $0.artistName)
                }
                if let url = match?.previewAssets?.first?.url { return .found(url) }
            }
        } catch {
            hadError = true
        }

        return hadError ? .failed : .unavailable
    }

    /// Titles must match word for word, so a remix or live version never
    /// stands in for the original. Artists may differ by featured names.
    private static func isCloseMatch(
        title: String,
        artist: String,
        candidateTitle: String,
        candidateArtist: String
    ) -> Bool {
        let titleWords = words(in: title)
        guard !titleWords.isEmpty, titleWords == words(in: candidateTitle) else { return false }

        let artistWords = Set(words(in: artist))
        let candidateArtistWords = Set(words(in: candidateArtist))
        guard !artistWords.isEmpty, !candidateArtistWords.isEmpty else { return false }
        return artistWords.isSubset(of: candidateArtistWords)
            || candidateArtistWords.isSubset(of: artistWords)
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
