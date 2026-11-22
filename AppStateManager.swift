//
//  AppStateManager.swift
//  Retune
//
//  Central source of truth for authentication and app routing state.
//  All views read from this — nothing checks MusicKit or Keychain directly.
//

import SwiftUI
import MusicKit
import Combine

// MARK: - Connected Service

enum ConnectedService: Equatable {
    case appleMusic         // Only Apple Music connected
    case spotify            // Only Spotify connected
    case both               // Both connected — picker shown in HomeView
    case none
}

// MARK: - App Phase (drives root routing)

enum AppPhase: Equatable {
    case launching          // Splash screen — checking auth state
    case onboarding         // First-time or fully logged-out user
    case home               // Authenticated, go to main app
}

// MARK: - AppStateManager

@MainActor
final class AppStateManager: ObservableObject {

    static let shared = AppStateManager()

    // MARK: - Published state

    @Published private(set) var phase: AppPhase = .launching
    @Published private(set) var connectedService: ConnectedService = .none

    /// When both services are connected, this tracks which one HomeView is
    /// currently showing. Defaults to Apple Music. Toggled by the picker.
    @Published var activeService: MusicPlatform = .appleMusic

    // MARK: - Private

    private let onboardingKey = "hasCompletedOnboarding"
    private let appleMusicDisconnectedKey = "appleMusicDisconnectedFromRetune"

    private init() {
        // Spotify is not a supported service yet. Remove credentials left by
        // earlier development builds so they cannot hijack app routing.
        SpotifyAuthManager.shared.clearLegacyCredentials()
    }

    // MARK: - Boot sequence (called from LaunchScreenView)

    func boot() async {
        // Route from Retune's local connection state instead of making launch
        // wait for MusicKit to resolve the device's Apple Music account. The
        // playlist request performs the authoritative permission check.
        try? await Task.sleep(for: .milliseconds(350))

        if hasCompletedOnboarding && !isAppleMusicDisconnected {
            connectedService = .appleMusic
            activeService = .appleMusic
            phase = .home
        } else {
            connectedService = .none
            phase = .onboarding
        }
    }

    // MARK: - Service detection

    func refreshServiceState() async {
        let appleMusicAuthorized =
            MusicAuthorization.currentStatus == .authorized && !isAppleMusicDisconnected
        connectedService = appleMusicAuthorized ? .appleMusic : .none
        activeService = .appleMusic
    }

    // MARK: - Onboarding

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: onboardingKey)
    }

    private var isAppleMusicDisconnected: Bool {
        UserDefaults.standard.bool(forKey: appleMusicDisconnectedKey)
    }

    func completeOnboarding() {
        // This screen is reachable only after MusicAuthorization succeeds.
        // Do not revalidate MusicKit/account state here: Apple's account
        // daemon can be slow or temporarily unavailable, and onboarding
        // completion is a local navigation decision.
        UserDefaults.standard.set(false, forKey: appleMusicDisconnectedKey)
        UserDefaults.standard.set(true, forKey: onboardingKey)
        connectedService = .appleMusic
        activeService = .appleMusic
        phase = .home
    }

    // MARK: - Connect / Disconnect

    @discardableResult
    func connectAppleMusic() async -> Bool {
        let status = await MusicAuthorization.request()
        if status == .authorized {
            UserDefaults.standard.set(false, forKey: appleMusicDisconnectedKey)
            connectedService = .appleMusic
            activeService = .appleMusic
        }
        return status == .authorized
    }

    func disconnectSpotify() async {
        SpotifyAuthManager.shared.clearLegacyCredentials()
        await refreshServiceState()
    }

    func disconnectAppleMusic() async {
        UserDefaults.standard.set(true, forKey: appleMusicDisconnectedKey)
        connectedService = .none
        activeService = .appleMusic
        phase = .onboarding
    }
}
