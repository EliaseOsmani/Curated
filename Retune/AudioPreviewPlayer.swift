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
    private let fadeInDuration: Double = 0.6
    private let fadeOutDuration: Double = 0.4
    /// About 60 volume updates a second, so the ramp has no audible steps.
    private let fadeStepDuration: Double = 1.0 / 60.0

    private var player: AVPlayer?
    /// The current card's clip. Kept while muted so unmuting can start it.
    private var requestedURL: URL?
    private var isSessionActive = false
    private var resumeAfterInterruption = false

    private var playbackObserver: AnyCancellable?
    /// Fires shortly before the clip ends so it fades out instead of cutting off.
    private var endFadeObserver: (player: AVPlayer, token: Any)?
    private var endFadeSetupTask: Task<Void, Never>?
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

        scheduleEndFade(for: newPlayer)
        newPlayer.play()
    }

    /// Fades the clip out as it reaches its end.
    private func scheduleEndFade(for target: AVPlayer) {
        guard let asset = target.currentItem?.asset else { return }
        let lead = fadeOutDuration
        endFadeSetupTask = Task { [weak self] in
            guard let duration = try? await asset.load(.duration),
                  duration.isNumeric, duration.seconds > lead * 2,
                  !Task.isCancelled,
                  let self, self.player === target
            else { return }

            let fadeStart = CMTime(seconds: duration.seconds - lead, preferredTimescale: 600)
            let token = target.addBoundaryTimeObserver(
                forTimes: [NSValue(time: fadeStart)],
                queue: .main
            ) { [weak self, weak target] in
                MainActor.assumeIsolated {
                    guard let self, let target, self.player === target else { return }
                    self.fadeInTask?.cancel()
                    self.fadeInTask = self.ramp(target, to: 0, over: lead)
                }
            }
            self.endFadeObserver = (target, token)
        }
    }

    private func fadeIn(_ target: AVPlayer) {
        fadeInTask?.cancel()
        fadeInTask = ramp(target, to: 1, over: fadeInDuration)
    }

    /// Moves volume to `targetVolume` along an ease-in-out curve, which sounds
    /// smoother than a straight line.
    @discardableResult
    private func ramp(_ target: AVPlayer, to targetVolume: Float, over seconds: Double) -> Task<Void, Never> {
        let startVolume = target.volume
        let steps = max(1, Int((seconds / fadeStepDuration).rounded()))
        let stepDuration = Duration.seconds(fadeStepDuration)
        return Task {
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let t = Double(step) / Double(steps)
                let eased = Float(t * t * (3 - 2 * t))
                target.volume = startVolume + (targetVolume - startVolume) * eased
                try? await Task.sleep(for: stepDuration)
            }
        }
    }

    private func retireCurrentPlayer() {
        fadeInTask?.cancel()
        fadeInTask = nil
        playbackObserver = nil
        endFadeSetupTask?.cancel()
        endFadeSetupTask = nil
        if let observer = endFadeObserver {
            observer.player.removeTimeObserver(observer.token)
            endFadeObserver = nil
        }
        resumeAfterInterruption = false

        guard let outgoing = player else { return }
        player = nil

        let fade = ramp(outgoing, to: 0, over: fadeOutDuration)
        Task {
            await fade.value
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
            try? await Task.sleep(for: .seconds(self?.fadeOutDuration ?? 0.4) + .milliseconds(80))
            guard !Task.isCancelled, let self, self.player == nil else { return }
            self.isSessionActive = false
            // Deactivating blocks while audio stops, so keep it off the main thread.
            await Task.detached(priority: .userInitiated) {
                do {
                    try AVAudioSession.sharedInstance()
                        .setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    print("[Retune] Couldn't release audio session: \(error)")
                }
            }.value
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
