//
//  ProfileView.swift
//  Curated
//
//  Shows the connected service with a disconnect option.
//  Spotify is shown as "coming soon" until Extended Quota Mode is available.
//

import SwiftUI
import MusicKit
import SwiftData
import UIKit

struct ProfileView: View {

    @EnvironmentObject private var appState: AppStateManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @State private var showDisconnectAlert = false
    @State private var showConnectionError = false
    @State private var isConnectingAppleMusic = false

    var body: some View {
        List {
            // ── Connected service ──────────────────────────────────────────
            Section {
                connectedServiceCard
            } header: {
                Text("Connected Service")
            } footer: {
                Text("Curated uses this service to load your playlists and save sessions.")
            }

            // ── Spotify coming soon ────────────────────────────────────────
            Section {
                spotifyComingSoonRow
            } header: {
                Text("Coming Soon")
            } footer: {
                Text("Spotify support is in development and will be available in a future update.")
            }

            // ── App info ───────────────────────────────────────────────────
            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build",   value: buildNumber)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            "Disconnect Apple Music from Curated?",
            isPresented: $showDisconnectAlert,
            titleVisibility: .visible
        ) {
            Button("Disconnect & Keep Sessions", role: .destructive) {
                Task { await appState.disconnectAppleMusic() }
            }
            Button("Disconnect & Delete Sessions", role: .destructive) {
                deleteAppleMusicSessions()
                Task { await appState.disconnectAppleMusic() }
            }
            Button("Open iOS Settings") {
                openSystemSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Curated can disconnect locally, but only iOS Settings can revoke the system Music permission.")
        }
        .alert("Apple Music Access Needed", isPresented: $showConnectionError) {
            Button("Open iOS Settings") { openSystemSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Curated to access Media & Apple Music, then try connecting again.")
        }
    }

    // MARK: - Connected service card

    @ViewBuilder
    private var connectedServiceCard: some View {
        let isConnected = appState.connectedService == .appleMusic

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray5))
                    .frame(width: 44, height: 44)
                Image(systemName: "applelogo")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Music")
                    .font(.body.weight(.medium))
                HStack(spacing: 5) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(isConnected ? "Connected" : "Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isConnectingAppleMusic {
                ProgressView()
            } else if isConnected {
                Button(role: .destructive) {
                    showDisconnectAlert = true
                } label: {
                    Text("Disconnect")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Button("Connect") {
                    connectAppleMusic()
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Spotify coming soon row

    private var spotifyComingSoonRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray5))
                    .frame(width: 44, height: 44)
                Image(systemName: "music.note")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(.systemGray2))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Spotify")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Coming Soon")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.5))
                        .clipShape(Capsule())
                }
                Text("Full support coming in a future update")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - App info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private func deleteAppleMusicSessions() {
        let descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.platform == "appleMusic" }
        )
        guard let sessions = try? modelContext.fetch(descriptor) else { return }
        sessions.forEach { modelContext.delete($0) }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func connectAppleMusic() {
        guard !isConnectingAppleMusic else { return }
        isConnectingAppleMusic = true
        Task {
            let connected = await appState.connectAppleMusic()
            isConnectingAppleMusic = false
            if !connected {
                showConnectionError = true
            }
        }
    }
}
