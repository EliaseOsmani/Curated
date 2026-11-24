//
//  PreviewResolver.swift
//  Curated
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
        if isMusicVideo {
            let result = await CatalogMatch.musicVideo(title: title, artist: artist) {
                $0.previewAssets?.first?.url != nil
            }
            return outcome(result) { $0.previewAssets?.first?.url }
        } else {
            let result = await CatalogMatch.song(title: title, artist: artist, isrc: isrc) {
                $0.previewAssets?.first?.url != nil
            }
            return outcome(result) { $0.previewAssets?.first?.url }
        }
    }

    private static func outcome<Item>(_ result: CatalogMatch.Result<Item>, url: (Item) -> URL?) -> Outcome {
        switch result {
        case .found(let item): return url(item).map(Outcome.found) ?? .unavailable
        case .notFound: return .unavailable
        case .failed: return .failed
        }
    }
}

// MARK: - Catalog matching

/// Finds the Apple Music catalog item for a track. Used for previews and for
/// saving songs that are in a playlist but not in the user's library.
nonisolated enum CatalogMatch {
    enum Result<Item: Sendable>: Sendable {
        case found(Item)
        case notFound
        /// A request failed, likely from the network, so a retry may succeed.
        case failed
    }

    /// ISRC identifies the exact recording, so it's tried before a text search.
    @concurrent
    static func song(
        title: String,
        artist: String,
        isrc: String?,
        where accept: @Sendable (MusicKit.Song) -> Bool = { _ in true }
    ) async -> Result<MusicKit.Song> {
        var hadError = false

        if let isrc, !isrc.isEmpty {
            do {
                let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: isrc)
                if let match = try await request.response().items.first(where: accept) {
                    return .found(match)
                }
            } catch {
                hadError = true
            }
        }

        for term in searchTerms(title: title, artist: artist) {
            do {
                var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
                request.limit = 15
                let candidates = try await request.response().songs.filter(accept)
                if let match = bestMatch(title: title, artist: artist, in: candidates, title: \.title, artist: \.artistName) {
                    return .found(match)
                }
            } catch {
                hadError = true
            }
        }

        return hadError ? .failed : .notFound
    }

    @concurrent
    static func musicVideo(
        title: String,
        artist: String,
        where accept: @Sendable (MusicVideo) -> Bool = { _ in true }
    ) async -> Result<MusicVideo> {
        var hadError = false
        for term in searchTerms(title: title, artist: artist) {
            do {
                var request = MusicCatalogSearchRequest(term: term, types: [MusicVideo.self])
                request.limit = 15
                let candidates = try await request.response().musicVideos.filter(accept)
                if let match = bestMatch(title: title, artist: artist, in: candidates, title: \.title, artist: \.artistName) {
                    return .found(match)
                }
            } catch {
                hadError = true
            }
        }
        return hadError ? .failed : .notFound
    }

    // MARK: Matching rules

    /// The full title first. Tags like "(feat. …)" or "- 2011 Remaster" can
    /// keep search from returning the right song, so the bare title is next.
    private static func searchTerms(title: String, artist: String) -> [String] {
        let full = "\(title) \(artist)"
        let core = "\(coreTitle(title)) \(artist)"
        return core == full || coreTitle(title).isEmpty ? [full] : [full, core]
    }

    /// Prefers a word-for-word title match, then a match that differs only by
    /// tags that don't change the recording.
    private static func bestMatch<Item>(
        title: String,
        artist: String,
        in candidates: [Item],
        title candidateTitle: (Item) -> String,
        artist candidateArtist: (Item) -> String
    ) -> Item? {
        let sameArtist = candidates.filter { artistsMatch(artist, candidateArtist($0)) }
        let exactWords = words(in: title)
        if let exact = sameArtist.first(where: { words(in: candidateTitle($0)) == exactWords }) {
            return exact
        }
        return sameArtist.first { titlesMatchLoosely(title, candidateTitle($0)) }
    }

    /// Titles match when the main title is the same and any tags that mark a
    /// different recording (Remix, Live, Acoustic, Taylor's Version, …) agree.
    private static func titlesMatchLoosely(_ a: String, _ b: String) -> Bool {
        let coreA = words(in: coreTitle(a))
        guard !coreA.isEmpty, coreA == words(in: coreTitle(b)) else { return false }
        return significantTags(a) == significantTags(b)
    }

    /// Words in a title's tags that mean a different recording. Tags for
    /// featured artists and remasters, and words like "Version", are dropped.
    private static func significantTags(_ title: String) -> Set<String> {
        var result = Set<String>()
        for tag in tags(in: title) {
            let tagWords = words(in: tag)
            guard let first = tagWords.first, !featuringWords.contains(first) else { continue }
            for word in tagWords
            where !ignorableTagWords.contains(word) && !word.allSatisfy(\.isNumber) {
                result.insert(word)
            }
        }
        return result
    }

    /// The title without bracketed tags or a trailing " - …" tag.
    private static func coreTitle(_ title: String) -> String {
        var core = title
        while let range = core.range(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, options: .regularExpression) {
            core.removeSubrange(range)
        }
        if let dash = core.range(of: " - ") {
            core = String(core[..<dash.lowerBound])
        }
        return core.trimmingCharacters(in: .whitespaces)
    }

    private static func tags(in title: String) -> [String] {
        var tags: [String] = []
        var rest = title
        while let range = rest.range(of: #"[\(\[][^\)\]]*[\)\]]"#, options: .regularExpression) {
            tags.append(String(rest[range]))
            rest.removeSubrange(range)
        }
        if let dash = rest.range(of: " - ") {
            tags.append(String(rest[dash.upperBound...]))
        }
        return tags
    }

    /// Artists match when one is contained in the other, so "Artist" matches
    /// "Artist & Guest". Joining words are ignored.
    private static func artistsMatch(_ a: String, _ b: String) -> Bool {
        let wordsA = Set(words(in: a)).subtracting(artistJoinWords)
        let wordsB = Set(words(in: b)).subtracting(artistJoinWords)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
        return wordsA.isSubset(of: wordsB) || wordsB.isSubset(of: wordsA)
    }

    private static let featuringWords: Set<String> = ["feat", "ft", "featuring", "with"]
    private static let artistJoinWords: Set<String> = ["and", "the", "feat", "ft", "featuring", "with", "x"]
    private static let ignorableTagWords: Set<String> = [
        "remaster", "remastered", "remasters", "version", "album", "single",
        "explicit", "clean", "mono", "stereo", "deluxe", "edition", "bonus",
        "track", "digital", "anniversary", "expanded", "from", "the", "a", "an",
        "of", "and", "motion", "picture", "soundtrack", "film", "series", "original",
    ]
    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
