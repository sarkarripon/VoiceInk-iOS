//
//  VoiceInk_iosApp.swift
//  VoiceInk-ios
//
//  Created by Prakash Joshi on 12/08/2025.
//

import SwiftUI
import SwiftData

@main
struct VoiceInk_iosApp: App {
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @StateObject private var recordingManager = RecordingManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Discard any stale keyboard request flags first (a launch-time start
        // is already represented by the voiceink://record URL open, so
        // honoring the flag here would double-start)
        _ = AppGroupCoordinator.shared.checkAndConsumeStartRecordingFlag()
        _ = AppGroupCoordinator.shared.checkAndConsumeStopRecordingFlag()

        // Clear any stale recording state on app launch
        AppGroupCoordinator.shared.updateRecordingState(false)
        AppGroupCoordinator.shared.updateProcessingState(false)
        AppGroupCoordinator.shared.writeDiagMarker()
        AppGroupCoordinator.shared.appendDiag("APP: launched")
        print("🧹 Cleared stale recording state on app launch")
    }
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Transcription.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    ContentView()
                        .environmentObject(recordingManager)
                        .onOpenURL { url in
                            handleURL(url)
                        }
                } else {
                    OnboardingView(isOnboardingComplete: $hasCompletedOnboarding)
                        .onOpenURL { url in
                            handleURL(url)
                        }
                }
            }
            .onAppear {
                // Attach the SwiftData context so keyboard-initiated stops
                // work regardless of which view is on screen
                recordingManager.modelContext = sharedModelContainer.mainContext
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
        }
        .modelContainer(sharedModelContainer)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        AppGroupCoordinator.shared.appendDiag("APP: scenePhase -> \(phase)")
        switch phase {
        case .active:
            // Start the silent keep-alive engine while foregrounded — iOS can
            // refuse audio session activation once already in the background,
            // so it must be running BEFORE the app is backgrounded. It then
            // keeps the process alive so the keyboard can trigger recording
            // via Darwin notifications without opening the app.
            if AppSettings.shared.backgroundDictationEnabled && hasCompletedOnboarding {
                BackgroundKeepAliveService.shared.start()
            } else {
                BackgroundKeepAliveService.shared.stop()
            }
        default:
            // Keep the engine running across .inactive/.background
            break
        }
    }
    
    private func handleURL(_ url: URL) {
        guard url.scheme == "voiceink" else { return }
        
        switch url.host {
        case "record":
            print("🔗 URL scheme triggered: open app for recording")
            // Automatically start recording flow when opened from keyboard
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.recordingManager.startRecordingFlow()
            }
            print("📱 App opened via keyboard extension - starting recording")
        default:
            break
        }
    }
}
