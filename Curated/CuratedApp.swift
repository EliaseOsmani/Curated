//
//  CuratedApp.swift
//  Curated
//

import SwiftUI
import SwiftData

@main
struct CuratedApp: App {

    @StateObject private var appState = AppStateManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                switch appState.phase {
                case .launching:
                    LaunchScreenView()

                case .onboarding:
                    OnboardingView()
                        .transition(.opacity)

                case .home:
                    RootView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: appState.phase)
            .environmentObject(appState)
        }
        .modelContainer(for: SessionRecord.self)
    }
}
