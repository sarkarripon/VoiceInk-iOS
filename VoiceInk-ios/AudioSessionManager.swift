//
//  AudioSessionManager.swift
//  VoiceInk-ios
//
//  Manages audio session lifecycle with configurable timeout
//  Prevents "session activation failed" errors by keeping session active between recordings
//

import Foundation
import Combine
import AVFoundation

@MainActor
final class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()
    
    @Published var isSessionActive: Bool = false
    @Published var timeoutRemaining: TimeInterval = 0

    /// While the background keep-alive engine is running, the session must
    /// never be deactivated or the app gets suspended
    var isKeepAliveActive: Bool = false
    
    private var deactivationTimer: Timer?
    private let settings = AppSettings.shared
    
    private init() {}
    
    // MARK: - Public Interface
    
    /// Activates audio session for recording with optimal settings.
    /// MUST be non-mixable AND must never be re-configured from the
    /// background: iOS refuses BOTH mic start on mixable sessions and any
    /// category change/activation from the background (OSStatus 560557684
    /// '!int'). So the keep-alive holds this exact configuration from
    /// foreground onward, and this call becomes a no-op while it does.
    func activateSessionForRecording() throws {
        let audioSession = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]

        // Already configured and active (keep-alive holds it): touch nothing,
        // touching the session in the background would throw '!int'
        if isSessionActive,
           audioSession.category == .playAndRecord,
           audioSession.categoryOptions == options {
            cancelScheduledDeactivation()
            return
        }

        do {
            // Configure session for recording with background support
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: options
            )

            // Activate the session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            isSessionActive = true
            cancelScheduledDeactivation()

            print("🎙️ Audio session activated for recording")

        } catch let error as NSError {
            print("⚠️ Audio session activation failed: \(error.localizedDescription) (Code: \(error.code))")
            throw error
        }
    }
    
    /// Schedules session deactivation after configured timeout
    func scheduleDeactivation() {
        cancelScheduledDeactivation()
        
        let timeoutSeconds = settings.audioSessionTimeoutSeconds
        
        // If timeout is 0, deactivate immediately (legacy behavior)
        guard timeoutSeconds > 0 else {
            deactivateSession()
            return
        }
        
        timeoutRemaining = TimeInterval(timeoutSeconds)
        
        // Create timer that updates every second and deactivates when done
        deactivationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                self.timeoutRemaining -= 1
                
                if self.timeoutRemaining <= 0 {
                    self.deactivateSession()
                }
            }
        }
        
        print("🕒 Audio session deactivation scheduled in \(timeoutSeconds) seconds")
    }
    
    /// Extends the timeout period (called when new recording starts)
    func extendTimeout() {
        guard isSessionActive else { return }
        
        // Cancel current timer and reschedule
        scheduleDeactivation()
        print("⏰ Audio session timeout extended")
    }
    
    /// Immediately deactivates the session
    func deactivateSession() {
        cancelScheduledDeactivation()

        guard !isKeepAliveActive else {
            print("🌙 Skipping session deactivation - keep-alive active")
            return
        }
        guard isSessionActive else { return }
        
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isSessionActive = false
            timeoutRemaining = 0
            print("🔇 Audio session deactivated")
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
    
    /// Force immediate deactivation (for app backgrounding, etc.)
    func forceDeactivate() {
        cancelScheduledDeactivation()
        
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isSessionActive = false
            timeoutRemaining = 0
            print("🛑 Audio session force deactivated")
        } catch {
            print("⚠️ Failed to force deactivate audio session: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func cancelScheduledDeactivation() {
        deactivationTimer?.invalidate()
        deactivationTimer = nil
        timeoutRemaining = 0
    }
    
    // MARK: - Debug Helpers
    
    var debugInfo: [String: Any] {
        return [
            "isSessionActive": isSessionActive,
            "timeoutRemaining": timeoutRemaining,
            "hasScheduledDeactivation": deactivationTimer != nil,
            "configuredTimeout": settings.audioSessionTimeoutSeconds
        ]
    }
}

// MARK: - App Lifecycle Integration

extension AudioSessionManager {
    
    /// Call when app enters background
    func handleAppDidEnterBackground() {
        // Optionally force deactivate when app backgrounds
        // This depends on whether you want background recording capability
        print("📱 App entered background - audio session state: \(isSessionActive)")
    }
    
    /// Call when app becomes active
    func handleAppDidBecomeActive() {
        print("📱 App became active - audio session state: \(isSessionActive)")
    }
    
    /// Call when app will terminate
    func handleAppWillTerminate() {
        forceDeactivate()
    }
}
