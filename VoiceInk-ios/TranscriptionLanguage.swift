import Foundation

/// A spoken language the transcription model can be locked to. Forcing a
/// language stops the model from guessing (and mis-guessing) in noisy audio.
struct TranscriptionLanguage: Identifiable, Hashable {
    /// ISO 639-1 code sent to the API, or nil for automatic detection.
    let code: String?
    let name: String

    var id: String { code ?? "auto" }

    /// Sentinel for automatic detection (the model picks the language).
    static let auto = TranscriptionLanguage(code: nil, name: "Auto")

    /// Curated common set (matches what the Whisper/Groq APIs accept).
    static let all: [TranscriptionLanguage] = [
        .auto,
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "ru", name: "Russian"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "bn", name: "Bengali"),
        .init(code: "ur", name: "Urdu"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "pl", name: "Polish"),
        .init(code: "id", name: "Indonesian"),
        .init(code: "vi", name: "Vietnamese"),
        .init(code: "th", name: "Thai"),
        .init(code: "uk", name: "Ukrainian"),
    ]

    /// Display name for a stored code (falls back to the code itself).
    static func displayName(for code: String?) -> String {
        all.first { $0.code == code }?.name ?? code ?? "Auto"
    }
}
