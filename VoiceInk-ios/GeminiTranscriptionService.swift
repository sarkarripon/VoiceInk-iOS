//
//  GeminiTranscriptionService.swift
//

import Foundation

/// Transcribes audio through Gemini's multimodal `generateContent` endpoint.
/// The audio is base64-encoded inline and the model is prompted to transcribe it,
/// mirroring the Mac app's GeminiTranscriptionClient.
struct GeminiTranscriptionService: TranscriptionService {

    func transcribeAudioFile(apiBaseURL: URL, apiKey: String, model: String, fileURL: URL, language: String? = nil) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var prompt = "Please transcribe this audio file. Provide only the transcribed text."
        if let language, !language.isEmpty {
            prompt += " The audio language is \"\(language)\" (ISO 639-1)."
        }

        let audioData = try Data(contentsOf: fileURL)
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inlineData": [
                                "mimeType": mimeType(for: fileURL),
                                "data": audioData.base64EncodedString(),
                            ]
                        ],
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GeminiAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text,
              !text.isEmpty else {
            throw NSError(domain: "GeminiAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty transcription response"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func verifyAPIKey(apiBaseURL: URL, _ apiKey: String) async -> Bool {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return "audio/wav"
        }
    }
}
