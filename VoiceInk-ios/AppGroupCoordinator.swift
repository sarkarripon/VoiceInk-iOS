import Foundation

/// Handles communication between the main VoiceInk app and the keyboard extension
/// Uses App Groups + Darwin Notifications for reliable iOS-native communication
final class AppGroupCoordinator {
    static let shared = AppGroupCoordinator()
    
    // MARK: - Constants
    private let appGroupIdentifier = "group.com.sarkarripon.VoiceInk"
    
    // UserDefaults keys for persistent state
    private enum UserDefaultsKeys {
        static let shouldStartRecording = "shouldStartRecording"
        static let shouldStopRecording = "shouldStopRecording"
        static let isRecording = "isRecording"
        static let lastRecordingTimestamp = "lastRecordingTimestamp"
        static let isProcessing = "isProcessing"
        static let processingTimestamp = "processingTimestamp"
        static let pendingTranscript = "pendingTranscript"
        static let pendingTranscriptTimestamp = "pendingTranscriptTimestamp"
    }
    
    // Darwin notification names for real-time communication
    private enum NotificationNames {
        static let startRecording = "com.prakashjoshipax.VoiceInk.startRecording"
        static let stopRecording = "com.prakashjoshipax.VoiceInk.stopRecording"
        static let recordingStateChanged = "com.prakashjoshipax.VoiceInk.recordingStateChanged"
        static let transcriptionReady = "com.prakashjoshipax.VoiceInk.transcriptionReady"
        // State-encoding acks (Darwin notifications carry no payload, so the
        // state must be in the name). These work even without Full Access.
        static let didStartRecording = "com.prakashjoshipax.VoiceInk.didStartRecording"
        static let didStopRecording = "com.prakashjoshipax.VoiceInk.didStopRecording"
        static let startRecordingFailed = "com.prakashjoshipax.VoiceInk.startRecordingFailed"
    }
    
    // MARK: - Properties
    private let sharedDefaults: UserDefaults?
    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()

    // File-based channel in the shared container. More reliable than
    // UserDefaults across processes (no cfprefsd caching) and inspectable
    // from the outside for debugging.
    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }
    // Everything lives under Library/Caches: the devicectl file service can
    // only traverse Library/, and keeping tooling visibility makes the
    // channel debuggable from a Mac
    private var channelDir: URL? {
        guard let url = containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var requestsDir: URL? {
        guard let url = channelDir?.appendingPathComponent("requests", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    // Callbacks for the main app
    var onStartRecordingRequested: (() -> Void)?
    var onStopRecordingRequested: (() -> Void)?

    // Callbacks for the keyboard extension
    var onTranscriptionReady: (() -> Void)?
    var onRecordingDidStart: (() -> Void)?
    var onRecordingDidStop: (() -> Void)?
    var onStartRecordingFailed: (() -> Void)?
    
    // MARK: - Initialization
    private init() {
        sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)
        setupNotificationObservers()
    }
    
    deinit {
        removeNotificationObservers()
    }
    
    // MARK: - Public Interface for Keyboard Extension
    
    /// Call this from the keyboard extension to request recording start
    func requestStartRecording() {
        // File request is the reliable channel (the app polls it); the Darwin
        // notification is the low-latency fast path.
        writeRequestFile("start")
        sharedDefaults?.set(true, forKey: UserDefaultsKeys.shouldStartRecording)
        appendDiag("KB: start requested")

        // Send immediate notification
        postDarwinNotification(NotificationNames.startRecording)
    }

    /// Call this from the keyboard extension to request recording stop
    func requestStopRecording() {
        writeRequestFile("stop")
        sharedDefaults?.set(true, forKey: UserDefaultsKeys.shouldStopRecording)
        appendDiag("KB: stop requested")

        // Send immediate notification
        postDarwinNotification(NotificationNames.stopRecording)
    }

    // MARK: - File Request Channel

    private func writeRequestFile(_ name: String) {
        guard let dir = requestsDir else { return }
        let payload = String(Date().timeIntervalSince1970)
        try? payload.write(to: dir.appendingPathComponent("\(name).request"), atomically: true, encoding: .utf8)
    }

    /// App-side: consume a pending request file. Returns true only for fresh
    /// requests (< 10s old); stale files are discarded.
    func consumeRequestFile(_ name: String) -> Bool {
        guard let dir = requestsDir else { return false }
        let url = dir.appendingPathComponent("\(name).request")
        guard let payload = try? String(contentsOf: url, encoding: .utf8) else { return false }
        try? FileManager.default.removeItem(at: url)

        let age = Date().timeIntervalSince1970 - (TimeInterval(payload.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        return age < 10
    }

    // MARK: - Heartbeat + Diagnostics

    /// App-side: prove liveness to the keyboard (and to external debugging)
    func writeHeartbeat(_ state: String) {
        guard let url = channelDir?.appendingPathComponent("heartbeat.txt") else { return }
        try? "\(Date().timeIntervalSince1970) \(state)".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Keyboard-side: how long since the app last proved it is alive
    var appHeartbeatAge: TimeInterval {
        guard let url = channelDir?.appendingPathComponent("heartbeat.txt"),
              let payload = try? String(contentsOf: url, encoding: .utf8),
              let ts = TimeInterval(payload.split(separator: " ").first.map(String.init) ?? "") else {
            return .infinity
        }
        return Date().timeIntervalSince1970 - ts
    }

    /// Marker via the known-working UserDefaults channel to prove which code
    /// version runs and whether file-channel writes succeed
    func writeDiagMarker() {
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "diagMarkerV3")
        let fileOK: Bool
        if let url = channelDir?.appendingPathComponent("probe.txt") {
            fileOK = (try? "probe".write(to: url, atomically: true, encoding: .utf8)) != nil
        } else {
            fileOK = false
        }
        sharedDefaults?.set(fileOK, forKey: "fileChannelOK")
        sharedDefaults?.set(containerURL?.path ?? "nil", forKey: "containerPath")
    }

    /// Append a line to the shared diagnostic log (capped at ~256KB)
    func appendDiag(_ line: String) {
        guard let url = channelDir?.appendingPathComponent("diag.log") else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > 262_144 { return }
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    /// Get current recording state (for keyboard UI updates).
    /// Read-only: staleness is interpreted, never written back — only the
    /// main app may write isRecording.
    var isRecording: Bool {
        let storedState = sharedDefaults?.bool(forKey: UserDefaultsKeys.isRecording) ?? false
        let timestamp = sharedDefaults?.double(forKey: UserDefaultsKeys.lastRecordingTimestamp) ?? 0

        // If the stored state is more than 30 seconds old, consider it stale
        if storedState && (Date().timeIntervalSince1970 - timestamp) > 30 {
            return false
        }

        return storedState
    }

    /// Whether the main app is currently transcribing a finished recording.
    /// Read-only, same staleness rule as isRecording.
    var isProcessing: Bool {
        let storedState = sharedDefaults?.bool(forKey: UserDefaultsKeys.isProcessing) ?? false
        let timestamp = sharedDefaults?.double(forKey: UserDefaultsKeys.processingTimestamp) ?? 0

        // Transcription should never take minutes; treat old state as stale
        if storedState && (Date().timeIntervalSince1970 - timestamp) > 120 {
            return false
        }

        return storedState
    }

    /// Read and clear the transcript published by the main app (returns nil if none or stale)
    func consumePendingTranscript() -> String? {
        guard let defaults = sharedDefaults else { return nil }

        let timestamp = defaults.double(forKey: UserDefaultsKeys.pendingTranscriptTimestamp)
        guard timestamp > 0, let text = defaults.string(forKey: UserDefaultsKeys.pendingTranscript) else {
            return nil
        }

        // Always consume so we never insert twice
        defaults.removeObject(forKey: UserDefaultsKeys.pendingTranscript)
        defaults.set(0, forKey: UserDefaultsKeys.pendingTranscriptTimestamp)

        // Discard transcripts older than 3 minutes (user has moved on)
        let age = Date().timeIntervalSince1970 - timestamp
        guard age < 180, !text.isEmpty else { return nil }

        return text
    }

    // MARK: - Public Interface for Main App
    
    /// Call this from the main app to update recording state
    func updateRecordingState(_ isRecording: Bool) {
        sharedDefaults?.set(isRecording, forKey: UserDefaultsKeys.isRecording)
        // Update timestamp whenever state changes
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastRecordingTimestamp)

        // Notify keyboard with a state-encoding name so it gets a positive
        // ack even if the shared container is unreadable on its side
        postDarwinNotification(isRecording ? NotificationNames.didStartRecording : NotificationNames.didStopRecording)

        print("📡 Updated recording state: \(isRecording)")
    }

    /// Call this from the main app when a start request could not be honored
    /// (mic permission missing, recorder failed to start in background, ...)
    func notifyStartRecordingFailed() {
        postDarwinNotification(NotificationNames.startRecordingFailed)
    }

    /// Age of the current processing state (infinity when not processing)
    var processingAge: TimeInterval {
        let ts = sharedDefaults?.double(forKey: UserDefaultsKeys.processingTimestamp) ?? 0
        return ts > 0 ? Date().timeIntervalSince1970 - ts : .infinity
    }

    /// Call periodically from the main app while transcription runs so slow
    /// transcriptions aren't misread as stale by the keyboard
    func touchProcessingTimestamp() {
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.processingTimestamp)
    }

    /// Call this from the main app periodically while recording so the keyboard's
    /// staleness check doesn't flip long recordings back to idle
    func touchRecordingTimestamp() {
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastRecordingTimestamp)
    }

    /// Call this from the main app when transcription starts/stops
    func updateProcessingState(_ isProcessing: Bool) {
        sharedDefaults?.set(isProcessing, forKey: UserDefaultsKeys.isProcessing)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.processingTimestamp)
        postDarwinNotification(NotificationNames.recordingStateChanged)
    }

    /// Call this from the main app when a transcript is ready for the keyboard to insert
    func publishTranscript(_ text: String) {
        sharedDefaults?.set(text, forKey: UserDefaultsKeys.pendingTranscript)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.pendingTranscriptTimestamp)
        updateProcessingState(false)
        postDarwinNotification(NotificationNames.transcriptionReady)
        print("📤 Published transcript for keyboard (\(text.count) chars)")
    }
    
    /// Check and consume start recording flag (returns true if should start)
    func checkAndConsumeStartRecordingFlag() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        
        let shouldStart = defaults.bool(forKey: UserDefaultsKeys.shouldStartRecording)
        if shouldStart {
            // Consume the flag
            defaults.set(false, forKey: UserDefaultsKeys.shouldStartRecording)
            return true
        }
        return false
    }
    
    /// Check and consume stop recording flag (returns true if should stop)
    func checkAndConsumeStopRecordingFlag() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        
        let shouldStop = defaults.bool(forKey: UserDefaultsKeys.shouldStopRecording)
        if shouldStop {
            // Consume the flag
            defaults.set(false, forKey: UserDefaultsKeys.shouldStopRecording)
            return true
        }
        return false
    }
    
    // MARK: - Darwin Notifications (Real-time Communication)
    
    private func setupNotificationObservers() {
        guard let center = notificationCenter else { return }
        
        // Observe start recording notifications
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleStartRecordingNotification()
            },
            NotificationNames.startRecording as CFString,
            nil,
            .deliverImmediately
        )
        
        // Observe stop recording notifications
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleStopRecordingNotification()
            },
            NotificationNames.stopRecording as CFString,
            nil,
            .deliverImmediately
        )

        // Observe transcript-ready notifications (consumed by the keyboard extension)
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTranscriptionReadyNotification()
            },
            NotificationNames.transcriptionReady as CFString,
            nil,
            .deliverImmediately
        )

        // State acks + failure signal (consumed by the keyboard extension)
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { coordinator.onRecordingDidStart?() }
            },
            NotificationNames.didStartRecording as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { coordinator.onRecordingDidStop?() }
            },
            NotificationNames.didStopRecording as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { coordinator.onStartRecordingFailed?() }
            },
            NotificationNames.startRecordingFailed as CFString,
            nil,
            .deliverImmediately
        )
    }
    
    private func removeNotificationObservers() {
        guard let center = notificationCenter else { return }
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }
    
    private func postDarwinNotification(_ name: String) {
        guard let center = notificationCenter else { return }
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
    
    // MARK: - Notification Handlers
    
    private func handleStartRecordingNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.onStartRecordingRequested?()
        }
    }
    
    private func handleStopRecordingNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.onStopRecordingRequested?()
        }
    }

    private func handleTranscriptionReadyNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.onTranscriptionReady?()
        }
    }
    
    // MARK: - Debug Helpers
    
    /// Clear all shared data (useful for debugging)
    func clearAllSharedData() {
        guard let defaults = sharedDefaults else { return }
        defaults.removeObject(forKey: UserDefaultsKeys.shouldStartRecording)
        defaults.removeObject(forKey: UserDefaultsKeys.shouldStopRecording)
        defaults.removeObject(forKey: UserDefaultsKeys.isRecording)
        defaults.removeObject(forKey: UserDefaultsKeys.lastRecordingTimestamp)
    }
    
    /// Get debug info about current state
    func getDebugInfo() -> [String: Any] {
        guard let defaults = sharedDefaults else { return ["error": "No shared defaults"] }
        
        return [
            "shouldStartRecording": defaults.bool(forKey: UserDefaultsKeys.shouldStartRecording),
            "shouldStopRecording": defaults.bool(forKey: UserDefaultsKeys.shouldStopRecording),
            "isRecording": defaults.bool(forKey: UserDefaultsKeys.isRecording),
            "lastRecordingTimestamp": defaults.double(forKey: UserDefaultsKeys.lastRecordingTimestamp),
            "appGroupIdentifier": appGroupIdentifier
        ]
    }
}
