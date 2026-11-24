//
//  ImageLoader.swift
//  Retune
//
//  Created by Eliase Osmani on 2/11/26.
//

import Foundation
import UIKit
import Combine

@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?

    private var currentURL: URL?

    /// Starts with a cached image when available, so preloaded cards never
    /// flash a placeholder.
    init(url: URL? = nil) {
        currentURL = url
        if let url {
            image = ImageCache.shared.image(for: url)
        }
    }

    func load(from url: URL?) async {
        guard let url else {
            currentURL = nil
            image = nil
            return
        }

        // If already loaded for this URL, don't redo work
        if currentURL == url, image != nil { return }

        // Never keep showing the previous song's artwork.
        if currentURL != url { image = nil }
        currentURL = url

        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return }

        ImageCache.shared.set(img, for: url)

        // A slower response for an older song must not replace this one.
        guard currentURL == url else { return }
        image = img
    }

    /// Fetches artwork into the cache ahead of time.
    static func preload(_ url: URL?) async {
        guard let url, ImageCache.shared.image(for: url) == nil else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return }
        ImageCache.shared.set(img, for: url)
    }
}
