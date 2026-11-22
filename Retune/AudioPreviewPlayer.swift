//
//  AudioPreviewPlayer.swift
//  Retune
//
//  Created by Eliase Osmani on 2/11/26.
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioPreviewPlayer: ObservableObject {
    static let shared = AudioPreviewPlayer()

    @Published private(set) var isMuted: Bool

    private let mutedKey = "previewAudioMuted"
    private let fadeSteps = 8
    private let fadeStepDuration: Duration = .milliseconds(18)

    private var player: AVPlayer?
    /// The current card's clip. Kept while muted so unmuting can start it.
    private var requestedURL: URL?
    private var isSessionActive = false
    private var resumeAfterInterruption = false

    private var playbackObserver: AnyCancellable?
    private var interruptionObserver: AnyCancellable?
    private var fadeInTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?

    private init() {
        isMuted = UserDefaults.standard.bool(forKey: mutedKey)
        interruptionObserver = NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleInterruption(notification)
            }
    }

    // MARK: - Controls

    /// Plays a clip once. While muted, it only remembers the clip.
    func play(url: URL) {
        requestedURL = url
        guard !isMuted else { return }
        start(url)
    }

    /// Stops the clip between cards without giving up audio focus.
    func clear() {
        requestedURL = nil
        retireCurrentPlayer()
    }

    /// Stops the clip and lets music from other apps resume.
    func endSession() {
        requestedURL = nil
        retireCurrentPlayer()
        scheduleSessionDeactivation()
    }

    func toggleMute() {
        isMuted.toggle()
        UserDefaults.standard.set(isMuted, forKey: mutedKey)

        if isMuted {
            retireCurrentPlayer()
            scheduleSessionDeactivation()
        } else if let requestedURL {
            start(requestedURL)
        }
    }

    // MARK: - Playback

    private func start(_ url: URL) {
        retireCurrentPlayer()
        activateSession()

        let newPlayer = AVPlayer(url: url)
        newPlayer.volume = 0
        player = newPlayer

        // Fade once audio is actually playing, not while it's still buffering.
        playbackObserver = newPlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .first { $0 == .playing }
            .sink { [weak self, weak newPlayer] _ in
                guard let self, let newPlayer, self.player === newPlayer else { return }
                self.fadeIn(newPlayer)
            }

        newPlayer.play()
    }

    private func fadeIn(_ target: AVPlayer) {
        fadeInTask?.cancel()
        let steps = fadeSteps
        let stepDuration = fadeStepDuration
        fadeInTask = Task {
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                target.volume = Float(step) / Float(steps)
                try? await Task.sleep(for: stepDuration)
            }
        }
    }

    private func retireCurrentPlayer() {
        fadeInTask?.cancel()
        fadeInTask = nil
        playbackObserver = nil
        resumeAfterInterruption = false

        guard let outgoing = player else { return }
        player = nil

        let startVolume = outgoing.volume
        let steps = fadeSteps
        let stepDuration = fadeStepDuration
        Task {
            for step in 1...steps {
                outgoing.volume = startVolume * (1 - Float(step) / Float(steps))
                try? await Task.sleep(for: stepDuration)
            }
            outgoing.pause()
        }
    }

    // MARK: - Audio session

    private func activateSession() {
        deactivationTask?.cancel()
        deactivationTask = nil
        guard !isSessionActive else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            isSessionActive = true
        } catch {
            print("[Retune] Couldn't activate audio session: \(error)")
        }
    }

    private func scheduleSessionDeactivation() {
        guard isSessionActive else { return }
        deactivationTask?.cancel()
        deactivationTask = Task { [weak self] in
            // Wait for the outgoing clip to finish fading.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self, self.player == nil else { return }
            do {
                try AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("[Retune] Couldn't release audio session: \(error)")
            }
            self.isSessionActive = false
        }
    }

    // MARK: - Interruptions

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            resumeAfterInterruption = player?.timeControlStatus != .paused && player != nil
            player?.pause()
            isSessionActive = false

        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if resumeAfterInterruption, options.contains(.shouldResume), !isMuted {
                activateSession()
                player?.play()
            }
            resumeAfterInterruption = false

        @unknown default:
            break
        }
    }
}
