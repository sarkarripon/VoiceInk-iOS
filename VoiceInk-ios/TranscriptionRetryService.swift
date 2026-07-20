//
//  TranscriptionRetryService.swift
//  VoiceInk-ios
//
//  Created by AI Assistant on 12/08/2025.
//

import Foundation

class TranscriptionRetryService {
    private let postProcessor = LLMPostProcessor()
    
    static let shared = TranscriptionRetryService()
    
    private init() {}
    
    /// Retries transcription for a given note using current app settings
    func retranscribe(note: Transcription) async throws -> String {
        guard let audioPath = note.fullAudioPath,
              FileManager.default.fileExists(atPath: audioPath) else {
            throw TranscriptionError.audioFileNotFound
        }
        
        let settings = AppSettings.shared
        let provider = await settings.effectiveTranscriptionProvider
        let apiKey = await settings.apiKey(for: provider)
        let model = await settings.effectiveTranscriptionModel
        let language = await settings.effectiveTranscriptionLanguage

        guard !apiKey.isEmpty else {
            throw TranscriptionError.noApiKey
        }

        let fileURL = URL(fileURLWithPath: audioPath)
        let transcriptionService = TranscriptionServiceFactory.service(for: provider)

        // Shrink the upload for cloud providers; local Whisper keeps the WAV
        var uploadFileURL = fileURL
        var temporaryUpload: URL? = nil
        if provider != .local, let compressed = AudioUploadCompressor.compressForUpload(fileURL) {
            uploadFileURL = compressed
            temporaryUpload = compressed
        }
        defer {
            if let temporaryUpload {
                try? FileManager.default.removeItem(at: temporaryUpload)
            }
        }

        let rawText = try await transcriptionService.transcribeAudioFile(
            apiBaseURL: provider.baseURL,
            apiKey: apiKey,
            model: model,
            fileURL: uploadFileURL,
            language: language
        )
        
        // Clean up transcription
        let cleanedText = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n\n+", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        
        var finalText = cleanedText
        var usedPostProcessingModel: String? = nil

        // Optional post-processing with cross-provider fallbacks
        var postProcessingError: String? = nil
        if await settings.effectiveIsPostProcessingEnabled {
            let ppPrompt = await settings.effectiveCustomPrompt
            if !ppPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Snapshot MainActor-isolated settings once, then run the chain
                let (candidates, apiKeys) = await MainActor.run { () -> ([PostProcessingCandidate], [Provider: String]) in
                    let candidates = PostProcessingFailover.candidates(
                        primaryProvider: settings.effectivePostProcessingProvider,
                        primaryModel: settings.effectivePostProcessingModel,
                        fallbacks: settings.effectivePostProcessingFallbacks,
                        apiKeyLookup: { settings.apiKey(for: $0) }
                    )
                    let keys = Dictionary(uniqueKeysWithValues: candidates.map { ($0.provider, settings.apiKey(for: $0.provider)) })
                    return (candidates, keys)
                }
                if !candidates.isEmpty {
                    do {
                        let result = try await postProcessor.postProcessTranscript(
                            candidates: candidates,
                            apiKeyLookup: { apiKeys[$0] ?? "" },
                            prompt: ppPrompt,
                            transcript: cleanedText
                        )
                        finalText = result.text
                        usedPostProcessingModel = result.used.model
                    } catch {
                        // Post-processing failed, but transcription succeeded
                        postProcessingError = "Post-processing failed: \(error.localizedDescription)"
                        // Still use the cleaned transcription text
                        finalText = cleanedText
                    }
                }
            }
        }

        // Update note
        note.text = cleanedText
        note.enhancedText = (finalText == cleanedText) ? nil : finalText
        note.transcriptionModelName = model
        if await settings.effectiveIsPostProcessingEnabled {
            let defaultModel = await settings.effectivePostProcessingModel
            note.aiEnhancementModelName = usedPostProcessingModel ?? defaultModel
        }
        note.transcriptionStatus = .completed
        note.transcriptionError = postProcessingError
        
        return finalText
    }
}

enum TranscriptionError: LocalizedError {
    case audioFileNotFound
    case noApiKey
    
    var errorDescription: String? {
        switch self {
        case .audioFileNotFound:
            return "Audio file not found"
        case .noApiKey:
            return "No API key configured"
        }
    }
}
