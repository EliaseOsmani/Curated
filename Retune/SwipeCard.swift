//
//  SwipeCard.swift
//  Retune
//

import SwiftUI
import UIKit

struct SwipeCard: View {
    let song: Song
    let isTopCard: Bool
    let onSwipeFinished: (_ swipedRight: Bool) -> Void

    @State private var offset: CGSize = .zero
    @State private var rotation: Double = 0
    @State private var isDraggingEnabled = true

    // Haptics — distinct generators per direction (PDR: distinct patterns)
    @State private var lastThresholdState: ThresholdState = .none
    private let keepFeedback   = UIImpactFeedbackGenerator(style: .medium)
    private let removeFeedback = UIImpactFeedbackGenerator(style: .rigid)

    // Tint color driven by artwork (also passed up to parent for screen bg)
    @Binding var tintColor: Color

    // -1 (full remove) to 1 (full keep). Drives the fixed tag and screen glow.
    @Binding var dragProgress: CGFloat

    // Audio
    @StateObject private var audio = AudioPreviewPlayer.shared

    // PDR: ~40% screen width OR velocity > 500 pts/sec
    private let swipeThresholdRatio: CGFloat = 0.40
    private let velocityThreshold:   CGFloat = 500
    private let offscreenX:          CGFloat = 900

    enum ThresholdState { case none, left, right }

    var body: some View {
        GeometryReader { geo in
            let swipeThreshold = geo.size.width * swipeThresholdRatio

            ZStack(alignment: .bottom) {

                // ── HERO: Full-bleed album art ──────────────────────────────
                ArtworkView(url: song.artworkURL, tintColor: $tintColor)
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                // ── Gradient scrim so text is legible over art ──────────────
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                // ── Song info overlay at bottom ─────────────────────────────
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(song.artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.80))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            // Subtle tint border
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(tintColor.opacity(0.30), lineWidth: 1)
            )
            .offset(isTopCard ? offset : .zero)
            .rotationEffect(.degrees(isTopCard ? rotation : 0))
            .gesture(isTopCard && isDraggingEnabled ? dragGesture(threshold: swipeThreshold) : nil)
            .onAppear {
                keepFeedback.prepare()
                removeFeedback.prepare()
                if isTopCard { audio.play(url: song.previewURL) }
            }
            .onDisappear {
                if isTopCard {
                    audio.stop()
                    dragProgress = 0
                }
            }
        }
    }

    // MARK: - Drag Gesture

    private func dragGesture(threshold: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { gesture in
                offset   = gesture.translation
                rotation = Double(gesture.translation.width / 18)
                dragProgress = threshold > 0
                    ? min(1, max(-1, gesture.translation.width / threshold))
                    : 0
                handleThresholdHaptics(for: offset.width, threshold: threshold)
            }
            .onEnded { gesture in
                // PDR: commit on velocity > 500 pts/sec OR distance > threshold
                let velocity = abs(gesture.predictedEndTranslation.width - gesture.translation.width)
                let committedRight = offset.width > threshold  || (velocity > velocityThreshold && offset.width > 0)
                let committedLeft  = offset.width < -threshold || (velocity > velocityThreshold && offset.width < 0)

                if committedRight      { swipeOut(toRight: true) }
                else if committedLeft  { swipeOut(toRight: false) }
                else                   { snapBack() }
            }
    }

    // MARK: - Haptics (distinct per direction — PDR requirement)

    private func handleThresholdHaptics(for x: CGFloat, threshold: CGFloat) {
        let newState: ThresholdState
        if      x >  threshold { newState = .right }
        else if x < -threshold { newState = .left  }
        else                   { newState = .none  }

        if newState != lastThresholdState {
            switch newState {
            case .right: keepFeedback.impactOccurred();   keepFeedback.prepare()
            case .left:  removeFeedback.impactOccurred(); removeFeedback.prepare()
            case .none:  break
            }
            lastThresholdState = newState
        }
    }

    // MARK: - Animation helpers

    private func snapBack() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            offset   = .zero
            rotation = 0
            dragProgress = 0
        }
        lastThresholdState = .none
    }

    private func swipeOut(toRight: Bool) {
        isDraggingEnabled = false
        withAnimation(.easeOut(duration: 0.22)) {
            offset   = CGSize(width: toRight ? offscreenX : -offscreenX, height: offset.height * 0.2)
            rotation = toRight ? 18 : -18
            dragProgress = toRight ? 1 : -1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            lastThresholdState = .none
            isDraggingEnabled  = true
            if isTopCard { audio.stop() }
            withAnimation(.easeOut(duration: 0.2)) {
                dragProgress = 0
            }
            onSwipeFinished(toRight)
        }
    }
}

// MARK: - Swipe Feedback

/// Full-screen green or red glow that strengthens toward the swipe threshold.
struct SwipeGlow: View {
    @Binding var progress: CGFloat

    var body: some View {
        let color: Color = progress >= 0 ? .green : .red

        RadialGradient(
            colors: [color.opacity(0.35), color.opacity(0.95)],
            center: .center,
            startRadius: 120,
            endRadius: 560
        )
        .opacity(abs(progress))
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// KEEP or REMOVE tag that stays centered on screen while the card moves.
struct SwipeDecisionTag: View {
    @Binding var progress: CGFloat

    var body: some View {
        let isKeep = progress >= 0
        let color: Color = isKeep ? .green : .red
        let strength = min(1, max(0, (abs(progress) - 0.12) / 0.45))

        Label(isKeep ? "KEEP" : "REMOVE", systemImage: isKeep ? "checkmark" : "xmark")
            .font(.title.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 26)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.75), lineWidth: 2))
            .shadow(color: color.opacity(0.9), radius: 24)
            .scaleEffect(0.82 + 0.18 * strength)
            .opacity(strength)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
