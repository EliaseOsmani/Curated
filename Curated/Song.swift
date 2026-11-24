//
//  Song.swift
//  Curated
//
//  Created by Eliase Osmani on 2/10/26.
//

import Foundation
import MusicKit

nonisolated struct Song: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let artist: String
    let artworkURL: URL?
    let previewURL: URL?
    let musicItemID: String?
    /// Optional so sessions saved before this field existed still decode.
    let isMusicVideo: Bool?
    /// Finds the matching catalog recording. Absent from older saved sessions.
    let isrc: String?
    /// The Apple Music catalog ID for library songs. Absent from older sessions.
    let catalogID: String?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        previewURL: URL? = nil,
        musicItemID: String? = nil,
        isMusicVideo: Bool = false,
        isrc: String? = nil,
        catalogID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.previewURL = previewURL
        self.musicItemID = musicItemID
        self.isMusicVideo = isMusicVideo
        self.isrc = isrc
        self.catalogID = catalogID
    }
}
