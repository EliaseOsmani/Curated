//
//  ArtworkView.swift
//  Retune
//

import SwiftUI
import UIKit

struct ArtworkView: View {
    let url: URL?
    @Binding var tintColor: Color

    @StateObject private var loader: ImageLoader

    init(url: URL?, tintColor: Binding<Color>) {
        self.url = url
        _tintColor = tintColor
        _loader = StateObject(wrappedValue: ImageLoader(url: url))
    }

    var body: some View {
        Group {
            if let img = loader.image {
                Image(uiImage: img)
                    .resizable()
                    .task(id: url) {
                        let avg = await img.averageColorInBackground
                        guard !Task.isCancelled, let avg else { return }
                        tintColor = Color(uiColor: avg)
                    }
            } else {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(.systemGray4), Color(.systemGray6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: url) { await loader.load(from: url) }
    }
}
