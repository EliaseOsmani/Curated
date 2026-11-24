//
//  AppleMusicSave.swift
//  Retune
//
//  Saving a retuned playlist to Apple Music. Each kept song is matched to its
//  Apple Music catalog entry, then the playlist is written through the Apple
//  Music API. The server adds catalog songs to the user's iCloud library
//  directly, so it works for songs that aren't in the library. Adding through
//  MusicLibrary on the device silently drops those songs, because Retune
//  can't read the account's Sync Library setting.
//

import Foundation
import MusicKit

// MARK: - Missed songs

/// A kept song that didn't make it into the saved playlist, and why.
struct MissedSong: Identifiable, Hashable {
    enum Reason: Hashable {
        /// No match on Apple Music, and the song isn't in the library.
        case notOnAppleMusic
        /// On Apple Music, but not playable in the user's country or region.
        case notAvailableInRegion
        /// Apple Music didn't answer while looking the song up.
        case lookupFailed
        /// Apple Music didn't answer while adding the song.
        case addFailed
        /// Apple Music refused to add the catalog song.
        case rejected(detail: String?)
        /// Only in the library (for example, uploaded), and Apple Music refused it.
        case libraryOnlyRejected
        /// Apple Music confirmed the add, but its copy of the playlist lacks it.
        case notKept
    }

    let song: Song
    let reason: Reason
    var id: UUID { song.id }

    var explanation: String {
        switch reason {
        case .notOnAppleMusic:
            return "Couldn't find this song on Apple Music, so it can't be added to a playlist."
        case .notAvailableInRegion:
            return "This song isn't available on Apple Music in your country or region."
        case .lookupFailed:
            return "Apple Music didn't respond while looking it up. Check your connection and try again."
        case .addFailed:
            return "Apple Music didn't respond while adding it. Check your connection and try again."
        case .rejected(let detail):
            let base = "Apple Music wouldn't add it to the playlist."
            guard let detail, !detail.isEmpty else { return base }
            return "\(base) (\(detail))"
        case .libraryOnlyRejected:
            return "This song is only in your library, not on Apple Music, and Apple Music wouldn't add it. If you uploaded it, make sure it has finished syncing to your library."
        case .notKept:
            return "Apple Music confirmed it was added, but it isn't in the saved playlist."
        }
    }

    /// Trying again may succeed, because the cause was a connection problem.
    var isRetryable: Bool {
        switch reason {
        case .lookupFailed, .addFailed: return true
        default: return false
        }
    }
}

// MARK: - Resolving kept songs

/// What to do with one kept song.
nonisolated enum SaveResolution: Sendable {
    case add(AppleMusicLibraryAPI.Track)
    case missing(MissedSong.Reason)
}

nonisolated enum AppleMusicSaveResolver {

    /// Identifies a track across a session. Song.id changes on every fetch.
    static func key(for song: Song) -> String {
        song.musicItemID ?? song.id.uuidString
    }

    /// Finds the Apple Music entry for every kept song, one lookup per track.
    ///
    /// Order of preference:
    /// 1. The catalog ID the song already has, from its own play parameters,
    ///    or from the source playlist's copy for songs not in the library.
    ///    These name the exact recording.
    /// 2. A catalog match by ISRC, then by title and artist.
    /// 3. The library copy, for songs that are only in the library.
    @concurrent
    static func resolve(_ songs: [Song], sourcePlaylistID: String?) async -> [String: SaveResolution] {
        var unique: [String: Song] = [:]
        for song in songs where unique[key(for: song)] == nil {
            unique[key(for: song)] = song
        }

        var catalogIDs: [String: String] = [:]
        for (key, song) in unique {
            if let id = song.catalogID, !id.isEmpty {
                catalogIDs[key] = id
            } else if let id = song.musicItemID, !id.hasPrefix("i.") {
                catalogIDs[key] = id
            }
        }

        // Library songs carry their catalog ID in their play parameters.
        let libraryEntries = unique.filter { $0.value.musicItemID?.hasPrefix("i.") == true }
        let library = await libraryLookup(
            songIDs: libraryEntries.values.filter { $0.isMusicVideo != true }.compactMap(\.musicItemID),
            videoIDs: libraryEntries.values.filter { $0.isMusicVideo == true }.compactMap(\.musicItemID)
        )
        catalogIDs.merge(library.catalogIDs) { existing, _ in existing }

        // Songs that aren't in the library: the source playlist's copy has it.
        let stillNeeded = Set(libraryEntries.keys).subtracting(catalogIDs.keys)
        if !stillNeeded.isEmpty, let sourcePlaylistID {
            let fromPlaylist = await sourcePlaylistCatalogIDs(playlistID: sourcePlaylistID, matching: stillNeeded)
            catalogIDs.merge(fromPlaylist) { existing, _ in existing }
        }

        // Confirm each catalog ID is playable in the user's storefront.
        var results: [String: SaveResolution] = [:]
        var regionBlocked = Set<String>()
        var lookupFailed = Set<String>()

        let songCatalogIDs = catalogIDs.filter { unique[$0.key]?.isMusicVideo != true }
        let videoCatalogIDs = catalogIDs.filter { unique[$0.key]?.isMusicVideo == true }
        let playableSongs = await playableCatalogSongIDs(Array(Set(songCatalogIDs.values)))
        let playableVideos = await playableCatalogVideoIDs(Array(Set(videoCatalogIDs.values)))

        for (key, catalogID) in songCatalogIDs {
            guard let playableSongs else { lookupFailed.insert(key); continue }
            if playableSongs.contains(catalogID) {
                results[key] = .add(.init(id: catalogID, type: "songs"))
            } else {
                regionBlocked.insert(key)
            }
        }
        for (key, catalogID) in videoCatalogIDs {
            guard let playableVideos else { lookupFailed.insert(key); continue }
            if playableVideos.contains(catalogID) {
                results[key] = .add(.init(id: catalogID, type: "music-videos"))
            } else {
                regionBlocked.insert(key)
            }
        }

        // Search for the rest. A blocked recording may have another release
        // (a single or a compilation) that is available.
        let remaining = unique.filter { results[$0.key] == nil }
        let searched = await searchCatalog(Array(remaining.values))

        for (key, song) in remaining {
            switch searched[key] {
            case .found(let track)?:
                NSLog("[Retune] Save: \"%@\" had no catalog ID; search found %@ %@",
                      song.title, track.type, track.id)
                results[key] = .add(track)
            case .failed?, nil:
                results[key] = library.found.contains(key)
                    ? .add(libraryTrack(for: song))
                    : .missing(.lookupFailed)
            case .notFound?:
                if library.found.contains(key) {
                    NSLog("[Retune] Save: \"%@\" had no catalog ID and no search match; sending library copy %@",
                          song.title, key)
                    results[key] = .add(libraryTrack(for: song))
                } else if regionBlocked.contains(key) {
                    results[key] = .missing(.notAvailableInRegion)
                } else if lookupFailed.contains(key) {
                    // Its catalog ID couldn't be checked, so it may still exist.
                    results[key] = .missing(.lookupFailed)
                } else {
                    results[key] = .missing(.notOnAppleMusic)
                }
            }
        }

        let adds = results.values.filter { if case .add = $0 { return true } else { return false } }.count
        NSLog("[Retune] Save: resolved %d of %d unique songs (%d had an exact catalog ID, %d region-blocked)",
              adds, unique.count, catalogIDs.count, regionBlocked.count)
        return results
    }

    /// A catalog version of the song that differs from `excluded`, for when
    /// Apple Music refuses the track it was first sent as.
    @concurrent
    static func alternateTrack(
        for song: Song,
        excluding excluded: AppleMusicLibraryAPI.Track
    ) async -> AppleMusicLibraryAPI.Track? {
        let track: AppleMusicLibraryAPI.Track
        if song.isMusicVideo == true {
            guard case .found(let video) = await CatalogMatch.musicVideo(
                title: song.title, artist: song.artist, where: { $0.playParameters != nil }
            ) else { return nil }
            track = .init(id: video.id.rawValue, type: "music-videos")
        } else {
            guard case .found(let match) = await CatalogMatch.song(
                title: song.title, artist: song.artist, isrc: song.isrc, where: { $0.playParameters != nil }
            ) else { return nil }
            track = .init(id: match.id.rawValue, type: "songs")
        }
        return track == excluded ? nil : track
    }

    private static func libraryTrack(for song: Song) -> AppleMusicLibraryAPI.Track {
        .init(
            id: key(for: song),
            type: song.isMusicVideo == true ? "library-music-videos" : "library-songs"
        )
    }

    // MARK: Library

    /// Which library IDs exist, and the catalog IDs their play parameters name.
    private static func libraryLookup(
        songIDs: [String],
        videoIDs: [String]
    ) async -> (found: Set<String>, catalogIDs: [String: String]) {
        var found = Set<String>()
        var catalogIDs: [String: String] = [:]
        do {
            for batch in songIDs.chunked(into: 25) {
                var request = MusicLibraryRequest<MusicKit.Song>()
                request.filter(matching: \.id, memberOf: batch.map { MusicItemID($0) })
                request.limit = 25
                for song in try await request.response().items {
                    found.insert(song.id.rawValue)
                    if let id = catalogID(from: song.playParameters) { catalogIDs[song.id.rawValue] = id }
                }
            }
            for batch in videoIDs.chunked(into: 25) {
                var request = MusicLibraryRequest<MusicVideo>()
                request.filter(matching: \.id, memberOf: batch.map { MusicItemID($0) })
                request.limit = 25
                for video in try await request.response().items {
                    found.insert(video.id.rawValue)
                    if let id = catalogID(from: video.playParameters) { catalogIDs[video.id.rawValue] = id }
                }
            }
        } catch {
            NSLog("[Retune] Save: library lookup failed: %@", String(describing: error))
        }
        return (found, catalogIDs)
    }

    /// Catalog IDs from the source playlist's copies of the given tracks.
    /// Track IDs stay the same across fetches, so they match the session.
    private static func sourcePlaylistCatalogIDs(playlistID: String, matching keys: Set<String>) async -> [String: String] {
        guard !playlistID.hasPrefix("spotify:") else { return [:] }
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: MusicItemID(playlistID))
            guard let playlist = try await request.response().items.first else { return [:] }

            var result: [String: String] = [:]
            for track in try await AppleMusicTracks.all(in: playlist) {
                switch track {
                case .song(let song) where keys.contains(song.id.rawValue):
                    if let id = catalogID(from: song.playParameters) { result[song.id.rawValue] = id }
                case .musicVideo(let video) where keys.contains(video.id.rawValue):
                    if let id = catalogID(from: video.playParameters) { result[video.id.rawValue] = id }
                default:
                    break
                }
            }
            return result
        } catch {
            NSLog("[Retune] Save: couldn't read source playlist: %@", String(describing: error))
            return [:]
        }
    }

    /// MusicKit doesn't expose a library song's catalog ID directly, but its
    /// play parameters carry it.
    static func catalogID(from parameters: PlayParameters?) -> String? {
        guard let parameters,
              let data = try? JSONEncoder().encode(parameters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["catalogId", "catalogID", "purchasedId"] {
            if let value = json[key] as? String, !value.isEmpty { return value }
            if let value = json[key] as? Int { return String(value) }
        }
        return nil
    }

    // MARK: Catalog

    /// The IDs that exist and are playable in the user's storefront, or nil if
    /// the lookup failed.
    private static func playableCatalogSongIDs(_ ids: [String]) async -> Set<String>? {
        var playable = Set<String>()
        do {
            for batch in ids.chunked(into: 25) {
                var request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, memberOf: batch.map { MusicItemID($0) })
                request.limit = 25
                for song in try await request.response().items where song.playParameters != nil {
                    playable.insert(song.id.rawValue)
                }
            }
            return playable
        } catch {
            NSLog("[Retune] Save: catalog lookup failed: %@", String(describing: error))
            return nil
        }
    }

    private static func playableCatalogVideoIDs(_ ids: [String]) async -> Set<String>? {
        var playable = Set<String>()
        do {
            for batch in ids.chunked(into: 25) {
                var request = MusicCatalogResourceRequest<MusicVideo>(matching: \.id, memberOf: batch.map { MusicItemID($0) })
                request.limit = 25
                for video in try await request.response().items where video.playParameters != nil {
                    playable.insert(video.id.rawValue)
                }
            }
            return playable
        } catch {
            NSLog("[Retune] Save: catalog video lookup failed: %@", String(describing: error))
            return nil
        }
    }

    private enum SearchResult: Sendable {
        case found(AppleMusicLibraryAPI.Track)
        case notFound
        case failed
    }

    /// Searches a few songs at a time to stay within Apple's rate limits.
    private static func searchCatalog(_ songs: [Song]) async -> [String: SearchResult] {
        let maxConcurrent = 4
        var results: [String: SearchResult] = [:]

        await withTaskGroup(of: (String, SearchResult).self) { group in
            var pending = songs[...]
            func addNext() {
                guard let song = pending.popFirst() else { return }
                group.addTask {
                    let result: SearchResult
                    if song.isMusicVideo == true {
                        switch await CatalogMatch.musicVideo(title: song.title, artist: song.artist, where: { $0.playParameters != nil }) {
                        case .found(let video): result = .found(.init(id: video.id.rawValue, type: "music-videos"))
                        case .notFound: result = .notFound
                        case .failed: result = .failed
                        }
                    } else {
                        switch await CatalogMatch.song(title: song.title, artist: song.artist, isrc: song.isrc, where: { $0.playParameters != nil }) {
                        case .found(let match): result = .found(.init(id: match.id.rawValue, type: "songs"))
                        case .notFound: result = .notFound
                        case .failed: result = .failed
                        }
                    }
                    return (key(for: song), result)
                }
            }

            for _ in 0..<maxConcurrent { addNext() }
            for await (key, result) in group {
                results[key] = result
                addNext()
            }
        }
        return results
    }
}

// MARK: - Apple Music API

/// Writes playlists through the Apple Music API. MusicDataRequest adds the
/// developer and user tokens.
nonisolated enum AppleMusicLibraryAPI {
    struct Track: Sendable, Hashable {
        let id: String
        /// "songs", "music-videos", "library-songs" or "library-music-videos".
        let type: String

        var isLibraryOnly: Bool { type.hasPrefix("library-") }
    }

    struct BadResponse: LocalizedError {
        var errorDescription: String? { "Apple Music sent an unexpected response." }
    }

    /// Creates an empty library playlist and returns its ID.
    @concurrent
    static func createPlaylist(name: String, description: String) async throws -> String {
        let body: [String: Any] = ["attributes": ["name": name, "description": description]]
        let data = try await post(path: "/v1/me/library/playlists", body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let id = items.first?["id"] as? String
        else { throw BadResponse() }
        return id
    }

    /// Appends tracks to a library playlist, in order.
    @concurrent
    static func add(_ tracks: [Track], to playlistID: String) async throws {
        let body: [String: Any] = ["data": tracks.map { ["id": $0.id, "type": $0.type] }]
        _ = try await post(path: "/v1/me/library/playlists/\(playlistID)/tracks", body: body)
    }

    /// The playlist's tracks as Apple Music's servers have them, as
    /// (title, artist) pairs. This is the authoritative copy. The device's
    /// copy can lag behind by a minute or more.
    @concurrent
    static func trackNames(in playlistID: String) async throws -> [(title: String, artist: String)] {
        try await serverTracks(in: playlistID).map { ($0.title, $0.artist) }
    }

    /// One track from Apple Music's server copy of a library playlist.
    struct ServerTrack: Sendable {
        let id: String
        let isMusicVideo: Bool
        let title: String
        let artist: String
        let artworkURL: URL?
        let catalogID: String?

        var song: Song {
            Song(
                title: title,
                artist: artist,
                artworkURL: artworkURL,
                musicItemID: id,
                isMusicVideo: isMusicVideo,
                catalogID: catalogID
            )
        }
    }

    /// Every track in Apple Music's server copy of a library playlist,
    /// following pages. Works before the playlist reaches the device.
    @concurrent
    static func serverTracks(in playlistID: String) async throws -> [ServerTrack] {
        var tracks: [ServerTrack] = []
        var path: String? = "/v1/me/library/playlists/\(playlistID)/tracks?limit=100"
        while let next = path {
            guard let url = URL(string: "https://api.music.apple.com" + next) else { throw BadResponse() }
            let data = try await MusicDataRequest(urlRequest: URLRequest(url: url, timeoutInterval: 30)).response().data
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BadResponse() }
            for item in json["data"] as? [[String: Any]] ?? [] {
                let attributes = item["attributes"] as? [String: Any] ?? [:]
                let artwork = (attributes["artwork"] as? [String: Any])?["url"] as? String
                let playParams = attributes["playParams"] as? [String: Any]
                tracks.append(ServerTrack(
                    id: item["id"] as? String ?? UUID().uuidString,
                    isMusicVideo: (item["type"] as? String) == "library-music-videos",
                    title: attributes["name"] as? String ?? "",
                    artist: attributes["artistName"] as? String ?? "",
                    artworkURL: artwork.flatMap {
                        URL(string: $0.replacingOccurrences(of: "{w}", with: "600")
                            .replacingOccurrences(of: "{h}", with: "600"))
                    },
                    catalogID: playParams?["catalogId"] as? String
                ))
            }
            path = json["next"] as? String
        }
        return tracks
    }

    private static func post(path: String, body: [String: Any]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = path
        guard let url = components.url else { throw BadResponse() }

        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await MusicDataRequest(urlRequest: urlRequest).response()
        return response.data
    }

    // MARK: Errors

    enum Failure {
        /// A connection or server problem. Trying again may work.
        case transient
        case notAuthorized
        case noSubscription
        /// An account problem the user can fix, with what to do.
        case account(String)
        /// Apple Music refused the request.
        case rejected(String?)
    }

    static func classify(_ error: Error) -> Failure {
        if let error = error as? MusicDataRequest.Error {
            NSLog("[Retune] Save: Apple Music API error %d: %@ %@", error.status, error.title, error.detailText)
            switch error.status {
            case 401: return .notAuthorized
            case 403: return .noSubscription
            case 408, 429, 500...599: return .transient
            default: return .rejected(error.detailText.isEmpty ? error.title : error.detailText)
            }
        }
        if let error = error as? MusicTokenRequestError {
            NSLog("[Retune] Save: token error: %@", String(describing: error))
            switch error {
            case .privacyAcknowledgementRequired:
                return .account("Open the Music app and accept Apple's privacy notice, then try again.")
            case .userNotSignedIn:
                return .account("Sign in to Apple Music in Settings → Apple Account → Media & Purchases, then try again.")
            case .permissionDenied:
                return .notAuthorized
            default:
                return .account("Apple Music couldn't confirm your account. Try again in a moment.")
            }
        }
        if error is URLError { return .transient }
        NSLog("[Retune] Save: write failed: %@", String(describing: error))
        return .rejected(error.localizedDescription)
    }
}

// MARK: - Helpers

nonisolated extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
