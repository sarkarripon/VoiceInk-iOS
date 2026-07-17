//
//  TranscriptionServiceFactory.swift
//

import Foundation

struct TranscriptionServiceFactory {
    static func service(for provider: Provider) -> TranscriptionService {
        switch provider {
        case .deepgram:
            return DeepgramTranscriptionService()
        case .assemblyai:
            return AssemblyAITranscriptionService()
        case .gemini:
            return GeminiTranscriptionService()
        case .groq, .openai, .cerebras, .voiceink:
            return GroqTranscriptionService()
        case .local:
            return WhisperTranscriptionService()
        }
    }
}