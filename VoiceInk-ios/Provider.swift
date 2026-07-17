import Foundation

enum ModelType {
    case transcription
    case postProcessing
}

enum Provider: String, CaseIterable, Codable, Identifiable {
    case groq = "Groq"
    case openai = "OpenAI"
    case deepgram = "Deepgram"
    case assemblyai = "AssemblyAI"
    case cerebras = "Cerebras"
    case gemini = "Gemini"
    case local = "Local (Whisper)"
    case voiceink = "VoiceInk"

    var id: String { rawValue }

    var baseURL: URL {
        switch self {
        case .groq: return URL(string: "https://api.groq.com/openai")!
        case .openai: return URL(string: "https://api.openai.com")!
        case .deepgram: return URL(string: "https://api.deepgram.com")!
        case .assemblyai: return URL(string: "https://api.assemblyai.com")!
        case .cerebras: return URL(string: "https://api.cerebras.ai")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        case .local: return URL(string: "http://localhost")! // Not used for local transcription
        case .voiceink: return URL(string: "https://api.groq.com/openai")! // VoiceInk uses Groq backend
        }
    }
    
    var consoleURL: URL {
        switch self {
        case .groq: return URL(string: "https://console.groq.com/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .deepgram: return URL(string: "https://console.deepgram.com/project/keys")!
        case .assemblyai: return URL(string: "https://www.assemblyai.com/app/api-keys")!
        case .cerebras: return URL(string: "https://cloud.cerebras.ai/platform")!
        case .gemini: return URL(string: "https://aistudio.google.com/app/apikey")!
        case .local: return URL(string: "https://github.com/ggerganov/whisper.cpp")! // Whisper.cpp GitHub page
        case .voiceink: return URL(string: "https://voiceink.app")! // VoiceInk website
        }
    }

    func models(for type: ModelType) -> [String] {
        switch (self, type) {
        case (.groq, .transcription):
            return [
                "whisper-large-v3",
                "whisper-large-v3-turbo",
                "whisper-medium",
                "whisper-small"
            ]
        case (.groq, .postProcessing):
            return [
                "llama-3.1-8b-instant",
                "llama-3.1-70b-versatile",
                "openai/gpt-oss-120b"
            ]
        case (.openai, .transcription):
            return [
                "whisper-1",
                "gpt-4o-transcribe",
                "gpt-4o-mini-transcribe"
            ]
        case (.openai, .postProcessing):
            return [
                "gpt-4o-mini",
                "gpt-3.5-turbo"
            ]
        case (.deepgram, .transcription):
            return [
                "nova-2",
                "nova-3"
            ]
        case (.deepgram, .postProcessing):
            return []
        case (.assemblyai, .transcription):
            return [
                "universal-3-5-pro",
                "universal-2"
            ]
        case (.assemblyai, .postProcessing):
            return [] // AssemblyAI is transcription-only
        case (.cerebras, .transcription):
            return []
        case (.cerebras, .postProcessing):
            return [
                "llama3.1-8b",
                "llama3.1-70b"
            ]
        case (.gemini, .transcription):
            // Fallback when the dynamic fetch hasn't run; Gemini transcribes
            // with the same multimodal chat models.
            return [
                "gemini-3.5-flash",
                "gemini-3.1-flash-lite",
                "gemini-3.1-pro-preview"
            ]
        case (.gemini, .postProcessing):
            return [
                "gemini-2.0-flash",
                "gemini-2.5-flash",
                "gemini-1.5-flash",
                "gemini-1.5-pro"
            ]
        case (.local, .transcription):
            return [
                "base"
            ]
        case (.local, .postProcessing):
            return [] // Local transcription doesn't support post-processing
        case (.voiceink, .transcription):
            return [] // Hardcoded: whisper-large-v3 (no user selection)
        case (.voiceink, .postProcessing):
            return [] // Hardcoded: gpt-oss-120b (no user selection)
        }
    }
}


