import Foundation
import os

struct LLMPostProcessor {
    private let client = OpenAICompatibleClient()
    private static let requestTimeout: TimeInterval = 15
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LLMPostProcessor")

    func postProcessTranscript(provider: Provider, apiKey: String, model: String, prompt: String, transcript: String) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }
        let result = try await client.chatCompletion(
            baseURL: provider.baseURL,
            apiKey: apiKey,
            model: model,
            messages: Self.messages(prompt: prompt, transcript: transcript),
            temperature: 0.2,
            timeout: Self.requestTimeout
        )
        return result.isEmpty ? transcript : result
    }

    /// Tries each candidate once, in order, advancing on transient failures.
    /// Returns the processed text and the candidate that produced it.
    func postProcessTranscript(
        candidates: [PostProcessingCandidate],
        apiKeyLookup: (Provider) -> String,
        prompt: String,
        transcript: String
    ) async throws -> (text: String, used: PostProcessingCandidate) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = candidates.first else {
            throw NSError(domain: "LLMPostProcessing", code: -1, userInfo: [NSLocalizedDescriptionKey: "No post-processing model configured"])
        }

        var lastError: Error = NSError(domain: "LLMPostProcessing", code: -1, userInfo: [NSLocalizedDescriptionKey: "Post-processing failed"])
        for candidate in candidates {
            do {
                let text = try await postProcessTranscript(
                    provider: candidate.provider,
                    apiKey: apiKeyLookup(candidate.provider),
                    model: candidate.model,
                    prompt: prompt,
                    transcript: transcript
                )
                if candidate != first {
                    Self.logger.notice("Post-processing succeeded with fallback \(candidate.provider.rawValue)/\(candidate.model)")
                }
                return (text, candidate)
            } catch {
                lastError = error
                guard PostProcessingFailover.isTransient(error) else { throw error }
                Self.logger.warning("\(candidate.provider.rawValue)/\(candidate.model) failed (\(error.localizedDescription)), trying next fallback")
            }
        }
        throw lastError
    }

    private static func messages(prompt: String, transcript: String) -> [OAChatMessage] {
        let systemPrompt = "You are a helpful assistant that rewrites raw speech-to-text transcripts to be concise, well-punctuated, and readable notes, preserving meaning."
        let contentPrompt = "Prompt: \(prompt)\n\nTranscript:\n\(transcript)"
        return [
            OAChatMessage(role: "system", content: systemPrompt),
            OAChatMessage(role: "user", content: contentPrompt)
        ]
    }
}


