//
//  AssemblyAITranscriptionService.swift
//

import Foundation

struct AssemblyAIUploadResponse: Decodable {
    let uploadURL: String

    enum CodingKeys: String, CodingKey {
        case uploadURL = "upload_url"
    }
}

struct AssemblyAITranscriptCreateResponse: Decodable {
    let id: String
}

struct AssemblyAITranscriptStatusResponse: Decodable {
    let status: String
    let text: String?
    let error: String?
}

struct AssemblyAITranscriptionService: TranscriptionService {
    // Batch flow: upload audio -> create transcript -> poll until completed.

    private static let pollIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let maxWaitSeconds: TimeInterval = 300

    func transcribeAudioFile(apiBaseURL: URL, apiKey: String, model: String, fileURL: URL, language: String? = nil) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)

        // 1. Upload raw audio
        var uploadRequest = URLRequest(url: apiBaseURL.appendingPathComponent("/v2/upload"))
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (uploadData, uploadResponse) = try await URLSession.shared.upload(for: uploadRequest, from: audioData)
        try Self.ensureSuccess(uploadResponse, data: uploadData)
        let uploadURL = try JSONDecoder().decode(AssemblyAIUploadResponse.self, from: uploadData).uploadURL

        // 2. Create transcript job
        var payload: [String: Any] = [
            "audio_url": uploadURL,
            "speech_models": [model],
            "punctuate": true,
            "format_text": true
        ]
        if let language, !language.isEmpty, language.lowercased() != "auto" {
            payload["language_code"] = language
        } else {
            payload["language_detection"] = true
        }

        var createRequest = URLRequest(url: apiBaseURL.appendingPathComponent("/v2/transcript"))
        createRequest.httpMethod = "POST"
        createRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (createData, createResponse) = try await URLSession.shared.data(for: createRequest)
        try Self.ensureSuccess(createResponse, data: createData)
        let transcriptID = try JSONDecoder().decode(AssemblyAITranscriptCreateResponse.self, from: createData).id

        // 3. Poll for completion
        let start = Date()
        while true {
            var pollRequest = URLRequest(url: apiBaseURL.appendingPathComponent("/v2/transcript/\(transcriptID)"))
            pollRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")

            let (pollData, pollResponse) = try await URLSession.shared.data(for: pollRequest)
            try Self.ensureSuccess(pollResponse, data: pollData)
            let decoded = try JSONDecoder().decode(AssemblyAITranscriptStatusResponse.self, from: pollData)

            switch decoded.status.lowercased() {
            case "completed":
                return decoded.text ?? ""
            case "error":
                throw NSError(domain: "AssemblyAIAPI", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: decoded.error ?? "AssemblyAI transcription failed"
                ])
            default:
                break
            }

            if Date().timeIntervalSince(start) > Self.maxWaitSeconds {
                throw NSError(domain: "AssemblyAIAPI", code: 408, userInfo: [
                    NSLocalizedDescriptionKey: "AssemblyAI transcription timed out"
                ])
            }
            try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }

    func verifyAPIKey(apiBaseURL: URL, _ apiKey: String) async -> Bool {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("/v2/transcript"))
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private static func ensureSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AssemblyAIAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
    }
}
