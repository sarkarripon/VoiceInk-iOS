import Foundation
import Combine

/// Fetches and caches the live model list from each provider's models API.
/// Falls back to the hardcoded lists in `Provider.models(for:)` when there is
/// no API key, no cached result, or the request fails.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    @Published private(set) var fetchedModels: [String: [String]] = [:]

    private var refreshesInFlight: Set<Provider> = []
    private static let storageKey = "fetchedProviderModels"

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String]] {
            fetchedModels = saved
        }
    }

    /// Live model list for a provider, falling back to the hardcoded list.
    func models(for provider: Provider, type: ModelType) -> [String] {
        if let fetched = fetchedModels[cacheKey(provider, type)], !fetched.isEmpty {
            return fetched
        }
        return provider.models(for: type)
    }

    /// Fetches the current model list from the provider's API and caches it.
    func refresh(_ provider: Provider) async {
        let apiKey = AppSettings.shared.apiKey(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !refreshesInFlight.contains(provider) else { return }

        refreshesInFlight.insert(provider)
        defer { refreshesInFlight.remove(provider) }

        do {
            switch provider {
            case .gemini:
                let models = try await fetchGeminiModels(apiKey: apiKey)
                // Gemini transcribes via the same multimodal chat models,
                // so one fetched list serves both purposes.
                store(models, for: provider, type: .transcription)
                store(models, for: provider, type: .postProcessing)
            case .groq:
                let ids = try await fetchOpenAICompatibleModels(
                    url: provider.baseURL.appendingPathComponent("v1/models"), apiKey: apiKey)
                store(
                    ids.filter { $0.lowercased().contains("whisper") }.sorted(),
                    for: provider, type: .transcription)
                let excluded = ["whisper", "tts", "guard"]
                store(
                    ids.filter { id in !excluded.contains { id.lowercased().contains($0) } }.sorted(),
                    for: provider, type: .postProcessing)
            case .openai:
                let ids = try await fetchOpenAICompatibleModels(
                    url: provider.baseURL.appendingPathComponent("v1/models"), apiKey: apiKey)
                store(
                    ids.filter { id in
                        let lower = id.lowercased()
                        return lower.contains("whisper") || lower.contains("transcribe")
                    }.sorted(),
                    for: provider, type: .transcription)
                store(filterOpenAIChatModels(ids), for: provider, type: .postProcessing)
            case .cerebras:
                let ids = try await fetchOpenAICompatibleModels(
                    url: provider.baseURL.appendingPathComponent("v1/models"), apiKey: apiKey)
                store(ids.sorted(), for: provider, type: .postProcessing)
            case .deepgram, .assemblyai, .local, .voiceink:
                break // No usable models endpoint; hardcoded lists stay.
            }
        } catch {
            // Keep the cached/hardcoded list on failure.
        }
    }

    // MARK: - Private

    private func cacheKey(_ provider: Provider, _ type: ModelType) -> String {
        "\(provider.rawValue)-\(type == .transcription ? "transcription" : "postProcessing")"
    }

    private func store(_ models: [String], for provider: Provider, type: ModelType) {
        guard !models.isEmpty else { return }
        fetchedModels[cacheKey(provider, type)] = models
        UserDefaults.standard.set(fetchedModels, forKey: Self.storageKey)
    }

    private func fetchGeminiModels(apiKey: String) async throws -> [String] {
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]

        let data = try await performGET(URLRequest(url: components.url!, timeoutInterval: 15))

        struct GeminiModel: Decodable {
            let name: String
            let supportedGenerationMethods: [String]?
        }
        struct Response: Decodable {
            let models: [GeminiModel]?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.models ?? [])
            .filter { model in
                model.name.contains("gemini")
                    && (model.supportedGenerationMethods ?? []).contains("generateContent")
            }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
            .sorted(by: >)
    }

    private func fetchOpenAICompatibleModels(url: URL, apiKey: String) async throws -> [String] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data = try await performGET(request)

        struct Model: Decodable {
            let id: String
        }
        struct Response: Decodable {
            let data: [Model]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let models = response.data else {
            throw URLError(.cannotParseResponse)
        }
        return models.map { $0.id }
    }

    private func filterOpenAIChatModels(_ ids: [String]) -> [String] {
        let excluded = [
            "instruct", "audio", "realtime", "search", "transcribe", "tts", "image",
            "embedding", "moderation", "dall-e", "whisper", "davinci", "babbage", "codex",
        ]
        return ids
            .filter { id in
                let lower = id.lowercased()
                let isChatFamily = lower.hasPrefix("gpt-") || lower.hasPrefix("chatgpt")
                    || lower.range(of: "^o[0-9]", options: .regularExpression) != nil
                return isChatFamily && !excluded.contains { lower.contains($0) }
            }
            .sorted(by: >)
    }

    private func performGET(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
