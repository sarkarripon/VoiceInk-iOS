import SwiftUI
import SwiftData
import AVFoundation
import Combine
import UIKit

extension Notification.Name {
    static let stopRecordingFromKeyboard = Notification.Name("stopRecordingFromKeyboard")
}

enum RecordingState: Equatable {
    case idle
    case recording
    case processing
    case completed(String)
    case error(String)
}

private enum MicrophonePermissionStatus {
    case granted, denied, undetermined
}

enum ActiveRecordingAlert: Identifiable {
    case permissionDenied
    case busy
    case generic(Error)
    
    var id: String {
        switch self {
        case .permissionDenied: return "permissionDenied"
        case .busy: return "busy"
        case .generic(let error): return "generic-\(error.localizedDescription)"
        }
    }
}
 
@MainActor
final class RecordingManager: ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var animate = false
    @Published var isRecordingSheetPresented = false
    @Published var activeRecordingAlert: ActiveRecordingAlert?
    @Published var currentRecordingNote: Transcription?
    @Published var currentDuration: Double = 0
    
    private let recorder = AudioRecorder()
    private let postProcessor = LLMPostProcessor()
    private let settings = AppSettings.shared
    private var durationTimer: Timer?

    private let sessionManager = AudioSessionManager.shared
    private let coordinator = AppGroupCoordinator.shared

    /// Set once at app startup so keyboard-initiated stops don't depend on
    /// any particular view being alive
    var modelContext: ModelContext?

    /// Guards the async permission-request window against double starts
    private var isStartingRecording = false

    /// True when the active recording was requested by the keyboard extension;
    /// only then is the transcript published back for insertion
    private var startedFromKeyboard = false

    /// Non-nil while recording through the keep-alive engine's live input tap
    /// (the only mic path that can START while the app is in the background)
    private var engineCaptureURL: URL?
    
    var isRecording: Bool {
        recordingState == .recording
    }
    
    /// Polls the shared-container request files. This is the RELIABLE channel
    /// from the keyboard; Darwin notifications are just the fast path.
    private var requestPollTimer: Timer?
    private var heartbeatCounter = 0

    // MARK: - Initialization
    init() {
        print("🎙️ RecordingManager initialized")
        setupCoordinatorCallbacks()
        coordinator.writeHeartbeat("launched")
        startRequestPolling()
    }

    deinit {
        durationTimer?.invalidate()
        requestPollTimer?.invalidate()
    }

    // MARK: - Request Polling (keyboard -> app, file-based)
    private func startRequestPolling() {
        requestPollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }

                if self.coordinator.consumeRequestFile("start") {
                    self.coordinator.appendDiag("APP: start request via file (rec=\(self.isRecording))")
                    self.startRecordingFlow(fromKeyboard: true)
                }

                if self.coordinator.consumeRequestFile("stop") {
                    self.coordinator.appendDiag("APP: stop request via file (rec=\(self.isRecording))")
                    if self.isRecording, let context = self.modelContext {
                        self.stopRecording(modelContext: context)
                    }
                }

                // Heartbeat every ~3.5s so the keyboard (and remote debugging)
                // can tell the app is alive and scheduled
                self.heartbeatCounter += 1
                if self.heartbeatCounter % 5 == 0 {
                    let engineState = BackgroundKeepAliveService.shared.isActive ? "keepalive-on" : "keepalive-off"
                    self.coordinator.writeHeartbeat("\(self.recordingState) \(engineState)")
                }
            }
        }
    }
    
    // MARK: - Coordinator Setup
    private func setupCoordinatorCallbacks() {
        coordinator.onStartRecordingRequested = { [weak self] in
            guard let self = self else { return }
            // Called when the keyboard extension requests recording while the
            // app is alive in the background (no foregrounding needed)
            print("🎙️ Start recording requested from keyboard extension")
            self.startRecordingFlow(fromKeyboard: true)
        }

        coordinator.onStopRecordingRequested = { [weak self] in
            guard let self = self, self.isRecording else { return }
            print("🛑 Stop recording requested from keyboard extension")
            if let context = self.modelContext {
                self.stopRecording(modelContext: context)
            } else {
                // Fallback for the unlikely case the context isn't attached yet
                NotificationCenter.default.post(name: .stopRecordingFromKeyboard, object: nil)
            }
        }
    }
    
    // MARK: - Recording Flow (Simplified)
    

    
    // MARK: - Recording Flow
    func startRecordingFlow(fromKeyboard: Bool = false) {
        // Single idempotent entry point: the Darwin callback, the
        // voiceink://record URL handler, and UI buttons can all race here
        guard recordingState == .idle, !isStartingRecording else {
            print("⚠️ Recording already in progress - ignoring duplicate start")
            return
        }
        startedFromKeyboard = fromKeyboard

        switch checkPermissionStatus() {
        case .granted:
            proceedToStartRecording()
        case .denied:
            activeRecordingAlert = .permissionDenied
            coordinator.notifyStartRecordingFailed()
        case .undetermined:
            isStartingRecording = true
            requestPermission { [weak self] granted in
                guard let self = self else { return }
                self.isStartingRecording = false
                if granted {
                    self.proceedToStartRecording()
                } else {
                    self.activeRecordingAlert = .permissionDenied
                    self.coordinator.notifyStartRecordingFailed()
                }
            }
        }
    }

    private func proceedToStartRecording() {
        recordingState = .recording
        animate = true

        // Auto-select first mode if none is selected
        if settings.selectedModeId == nil && !settings.modes.isEmpty {
            settings.selectedModeId = settings.modes.first?.id
        }

        do {
            if BackgroundKeepAliveService.shared.isActive {
                // Engine capture: writes the already-running input stream, so
                // it works from the background too
                let filename = "recording_\(Int(Date().timeIntervalSince1970)).wav"
                let url = AudioRecorder.recordingsDirectory().appendingPathComponent(filename)
                try BackgroundKeepAliveService.shared.startCapture(to: url)
                engineCaptureURL = url
            } else {
                try recorder.startRecording()
            }
            // Publish cross-process state only once recording is truly active
            coordinator.updateRecordingState(true)
            coordinator.appendDiag("APP: recording STARTED")
            BackgroundKeepAliveService.shared.noteActivity()
            startDurationTimer()
            isRecordingSheetPresented = true
        } catch {
            activeRecordingAlert = .generic(error)
            recordingState = .idle
            animate = false
            coordinator.updateRecordingState(false)
            coordinator.notifyStartRecordingFailed()
            coordinator.appendDiag("APP: recording start FAILED: \(error.localizedDescription)")
        }
    }
    
    func stopRecording(modelContext: ModelContext) {
        // Stop recording and get file info
        stopDurationTimer()

        let stoppedFileURL: URL?
        if engineCaptureURL != nil {
            stoppedFileURL = BackgroundKeepAliveService.shared.stopCapture()?.url
            engineCaptureURL = nil
        } else {
            recorder.stopRecording()
            stoppedFileURL = recorder.currentRecordingURL
            // Take ownership of the file synchronously so a later recording's
            // URL can't be clobbered by this recording's async cleanup
            recorder.currentRecordingURL = nil
            recorder.currentDuration = 0
        }

        guard let fileURL = stoppedFileURL else {
            // No active file (already cleaned up or start failed): fully
            // reset so the app and keyboard don't stay stuck in "recording"
            recordingState = .idle
            animate = false
            isRecordingSheetPresented = false
            coordinator.updateRecordingState(false)
            coordinator.updateProcessingState(false)
            return
        }

        // Store relative path and duration
        let audioFileName = fileURL.lastPathComponent
        let recordingDuration = currentDuration
        
        // IMMEDIATELY create and insert the note with pending status
        let note = Transcription(
            text: "",
            duration: recordingDuration,
            audioFileURL: audioFileName,
            transcriptionStatus: .pending
        )
        modelContext.insert(note)
        try? modelContext.save()
        
        // Reset UI state immediately so user can continue using the app
        recordingState = .idle
        animate = false
        currentRecordingNote = note
        isRecordingSheetPresented = false
        
        // Update coordinator state
        coordinator.updateRecordingState(false)
        coordinator.updateProcessingState(true)
        BackgroundKeepAliveService.shared.noteActivity()

        // Start background transcription
        transcribeInBackground(note: note, audioFileName: audioFileName, recordingDuration: recordingDuration, modelContext: modelContext)
    }
    
    func cancelRecording() {
        if engineCaptureURL != nil {
            BackgroundKeepAliveService.shared.cancelCapture()
            engineCaptureURL = nil
        } else {
            recorder.discard()
        }
        stopDurationTimer()
        recordingState = .idle
        animate = false
        isRecordingSheetPresented = false
        currentDuration = 0

        // Update coordinator state
        coordinator.updateRecordingState(false)
        coordinator.updateProcessingState(false)
    }
    
    // MARK: - Permissions
    private func checkPermissionStatus() -> MicrophonePermissionStatus {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
    
    private func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
    
    // MARK: - Duration Timer
    private func startDurationTimer() {
        currentDuration = 0
        var tickCount = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentDuration += 0.1
                tickCount += 1
                // Refresh the shared timestamp every 5s so the keyboard's
                // 30s staleness check doesn't reset long recordings to idle
                if tickCount % 50 == 0 {
                    self.coordinator.touchRecordingTimestamp()
                }
            }
        }
    }
    
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
    
    // MARK: - Transcription
    private func transcribeInBackground(note: Transcription, audioFileName: String, recordingDuration: Double, modelContext: ModelContext) {
        // Capture NOW: a new recording may start while this transcription runs
        let publishToKeyboard = startedFromKeyboard

        Task {
            // Keep the shared processing timestamp fresh so the keyboard's
            // staleness check doesn't misread slow transcriptions as dead
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    AppGroupCoordinator.shared.touchProcessingTimestamp()
                }
            }
            defer { heartbeat.cancel() }

            let settings = AppSettings.shared
            
            // Use effective settings from selected mode
            let provider = settings.effectiveTranscriptionProvider
            let apiKey = settings.apiKey(for: provider)
            let model = settings.effectiveTranscriptionModel
            
            // If no API key, update note with error
            guard !apiKey.isEmpty else {
                await MainActor.run {
                    note.transcriptionStatus = .failed
                    note.transcriptionError = "No API key configured"
                    try? modelContext.save()
                    coordinator.updateProcessingState(false)
                }
                return
            }
            
            do {
                // Resolve the relative path to absolute path for transcription
                let recordingsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Recordings")
                let fileURL = recordingsDir.appendingPathComponent(audioFileName)
                let service = TranscriptionServiceFactory.service(for: provider)
                let rawText = try await service.transcribeAudioFile(apiBaseURL: provider.baseURL, apiKey: apiKey, model: model, fileURL: fileURL, language: nil)
                
                // Clean up transcription
                let cleanedText = rawText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n\n+", with: "\n\n", options: .regularExpression)
                    .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                
                var finalText = cleanedText
                var enhancedText: String? = nil
                var postProcessingError: String? = nil
                
                // Optional post-processing
                if settings.effectiveIsPostProcessingEnabled {
                    let ppPrompt = settings.effectiveCustomPrompt
                    if !ppPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let llmProvider = settings.effectivePostProcessingProvider
                        let llmKey = settings.apiKey(for: llmProvider)
                        let llmModel = settings.effectivePostProcessingModel
                        if !llmKey.isEmpty {
                            do {
                                finalText = try await postProcessor.postProcessTranscript(provider: llmProvider, apiKey: llmKey, model: llmModel, prompt: ppPrompt, transcript: cleanedText)
                                enhancedText = finalText
                            } catch {
                                postProcessingError = "Post-processing failed: \(error.localizedDescription)"
                                finalText = cleanedText
                            }
                        }
                    }
                }
                
                // Update the existing note on main thread
                await MainActor.run {
                    note.text = cleanedText
                    note.enhancedText = enhancedText
                    note.transcriptionModelName = model
                    note.aiEnhancementModelName = settings.effectiveIsPostProcessingEnabled ? settings.effectivePostProcessingModel : nil
                    note.transcriptionStatus = .completed
                    note.transcriptionError = postProcessingError
                    try? modelContext.save()

                    // Hand the finished text to the keyboard extension, but
                    // only when the keyboard asked for this recording
                    if publishToKeyboard {
                        coordinator.publishTranscript(finalText)
                    } else {
                        coordinator.updateProcessingState(false)
                    }
                }

            } catch {
                // Update note with error on main thread
                await MainActor.run {
                    note.transcriptionStatus = .failed
                    note.transcriptionError = error.localizedDescription
                    try? modelContext.save()
                    coordinator.updateProcessingState(false)
                }
            }
        }
    }
}
