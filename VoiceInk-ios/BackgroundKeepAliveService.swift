//
//  BackgroundKeepAliveService.swift
//  VoiceInk-ios
//
//  Keeps the app alive in the background by playing silent audio, so the
//  keyboard extension can start/stop recording via Darwin notifications
//  without foregrounding the app. Personal-use feature: relies on the
//  `audio` UIBackgroundMode and will not pass App Store review.
//

import Foundation
import AVFoundation

@MainActor
final class BackgroundKeepAliveService {
    static let shared = BackgroundKeepAliveService()

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var graphBuilt = false
    private var tapInstalled = false
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?

    private(set) var isActive = false

    /// Shuts everything down after prolonged dictation inactivity so the mic
    /// stream and silent playback don't drain the battery forever. iOS then
    /// suspends the app; the keyboard's open-app fallback re-arms it.
    private var idleTimer: Timer?

    // Live microphone capture. iOS forbids STARTING mic input from the
    // background, so the input tap runs from foreground on (orange indicator
    // stays on while the app is alive) and "recording" just starts writing
    // the already-flowing buffers to a file.
    private let captureQueue = DispatchQueue(label: "voiceink.capture")
    private var captureFile: AVAudioFile? // touch only on captureQueue
    private var captureURL: URL?
    private var captureStartTime: Date?

    var isCapturing: Bool { captureQueue.sync { captureFile != nil } }

    private init() {}

    /// Start silent playback so iOS keeps the process running in the background.
    /// Also acts as a repair path: calling it while marked active but with a
    /// dead engine restarts everything. The microphone is NOT opened here —
    /// input only runs while an actual recording is in progress, so the orange
    /// indicator stays off when idle.
    func start() {
        guard !(isActive && engine.isRunning) else { return }

        do {
            // Recording-grade session held from the foreground on: iOS won't
            // let us switch to it later from the background
            try AudioSessionManager.shared.activateSessionForRecording()
            AudioSessionManager.shared.isKeepAliveActive = true

            buildGraphIfNeeded()
            installTapIfNeeded()
            player.stop() // clear any stale scheduled buffers
            scheduleSilence()

            try engine.start()
            player.play()

            observeInterruptions()
            observeMediaServicesReset()
            observeConfigurationChanges()
            isActive = true
            noteActivity()
            AppGroupCoordinator.shared.appendDiag("APP: keep-alive started (engine running=\(engine.isRunning))")
            print("🌙 Background keep-alive started")
        } catch {
            AudioSessionManager.shared.isKeepAliveActive = false
            AppGroupCoordinator.shared.appendDiag("APP: keep-alive start FAILED: \(error.localizedDescription)")
            print("⚠️ Background keep-alive failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isActive else { return }

        player.stop()
        engine.stop()

        removeObservers()
        idleTimer?.invalidate()
        idleTimer = nil

        AudioSessionManager.shared.isKeepAliveActive = false
        AudioSessionManager.shared.scheduleDeactivation()
        isActive = false
        print("🌅 Background keep-alive stopped")
    }

    /// Call on any dictation activity (start/stop/foreground) to postpone
    /// the idle hibernate
    func noteActivity() {
        idleTimer?.invalidate()
        idleTimer = nil

        let minutes = AppSettings.shared.keepAliveIdleMinutes
        guard isActive, minutes > 0 else { return }

        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { _ in
            Task { @MainActor in
                let service = BackgroundKeepAliveService.shared
                guard service.isActive, !service.isCapturing else {
                    service.noteActivity() // recording in flight - re-arm
                    return
                }
                AppGroupCoordinator.shared.appendDiag("APP: hibernating after \(minutes)min idle")
                AppGroupCoordinator.shared.writeHeartbeat("hibernated")
                service.stop()
            }
        }
    }

    /// Restart the engine if it died while we're supposed to be active
    func ensureRunning() {
        guard isActive, !engine.isRunning else { return }
        do {
            try AudioSessionManager.shared.activateSessionForRecording()
            AudioSessionManager.shared.isKeepAliveActive = true
            player.stop()
            scheduleSilence()
            try engine.start()
            player.play()
            print("🌙 Keep-alive engine restarted")
        } catch {
            print("⚠️ Keep-alive restart failed: \(error.localizedDescription)")
        }
    }

    /// Call after a recording ends: revive the silent engine if the recorder
    /// teardown stopped it (no session changes — background-forbidden)
    func reconfigureForIdle() {
        guard isActive else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            player.stop()
            scheduleSilence()
            player.play()
            AppGroupCoordinator.shared.appendDiag("APP: keep-alive engine revived after recording")
        } catch {
            AppGroupCoordinator.shared.appendDiag("APP: engine revive FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func buildGraphIfNeeded() {
        guard !graphBuilt else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: silenceFormat)
        engine.mainMixerNode.outputVolume = 0
        graphBuilt = true
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.captureQueue.async {
                guard let file = self.captureFile else { return } // idle: discard
                do {
                    try file.write(from: buffer)
                } catch {
                    print("⚠️ Capture write failed: \(error.localizedDescription)")
                }
            }
        }
        tapInstalled = true
    }

    // MARK: - Capture API (used for keyboard-triggered background recording)

    /// Begin writing the live input to a WAV file. Works in the background
    /// because the input stream is already running.
    func startCapture(to url: URL) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard engine.isRunning, format.sampleRate > 0 else {
            throw NSError(domain: "com.sarkarripon.VoiceInk.capture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Capture engine is not running"
            ])
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)

        captureQueue.sync {
            captureFile = file
        }
        captureURL = url
        captureStartTime = Date()
        AppGroupCoordinator.shared.appendDiag("APP: engine capture started (\(Int(format.sampleRate))Hz)")
    }

    /// Stop writing and return the finished file + duration
    func stopCapture() -> (url: URL, duration: TimeInterval)? {
        captureQueue.sync {
            captureFile = nil // AVAudioFile closes on release
        }
        guard let url = captureURL, let start = captureStartTime else { return nil }
        captureURL = nil
        captureStartTime = nil
        AppGroupCoordinator.shared.appendDiag("APP: engine capture stopped")
        return (url, Date().timeIntervalSince(start))
    }

    /// Discard an in-flight capture
    func cancelCapture() {
        captureQueue.sync { captureFile = nil }
        if let url = captureURL {
            try? FileManager.default.removeItem(at: url)
        }
        captureURL = nil
        captureStartTime = nil
    }

    private var silenceFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    }

    private func scheduleSilence() {
        let format = silenceFormat
        let frameCount = AVAudioFrameCount(format.sampleRate) // 1 second of silence
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount // samples are zero-initialized

        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            Task { @MainActor in
                guard let self, self.isActive else { return }

                switch type {
                case .began:
                    print("🌙 Keep-alive interrupted (call/other app)")
                case .ended:
                    self.ensureRunning()
                @unknown default:
                    break
                }
            }
        }
    }

    /// Media services daemon crash invalidates the entire engine graph;
    /// Apple requires rebuilding from scratch
    private func observeMediaServicesReset() {
        guard mediaResetObserver == nil else { return }

        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                print("🌙 Media services reset - rebuilding keep-alive engine")
                self.removeObservers() // config observer is bound to the old engine
                self.engine = AVAudioEngine()
                self.player = AVAudioPlayerNode()
                self.graphBuilt = false
                self.tapInstalled = false
                self.isActive = false
                self.start()
            }
        }
    }

    /// Route changes (headphones, Bluetooth) can stop the engine without an
    /// interruption notification
    private func observeConfigurationChanges() {
        guard configChangeObserver == nil else { return }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Let the configuration transition settle before restarting
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.ensureRunning()
            }
        }
    }

    private func removeObservers() {
        for observer in [interruptionObserver, mediaResetObserver, configChangeObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        interruptionObserver = nil
        mediaResetObserver = nil
        configChangeObserver = nil
    }
}
