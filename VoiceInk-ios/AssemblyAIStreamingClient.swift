//
//  AssemblyAIStreamingClient.swift
//  VoiceInk-ios
//
//  AssemblyAI Universal-Streaming (v3) websocket client. Sends raw PCM16,
//  16 kHz, mono, little-endian audio frames and receives live "Turn" events.
//  Adapted from LLMkit's AssemblyAIStreamingClient (github.com/Beingpax/LLMkit),
//  the same client the VoiceInk macOS app uses.
//

import Foundation

enum StreamingEvent {
    case sessionStarted
    case partial(text: String)
    case committed(text: String)
    case error(String)
}

final class AssemblyAIStreamingClient: @unchecked Sendable {
    private static let keytermLimit = 100
    // 50 ms of 16 kHz PCM16 — AssemblyAI rejects chunks under 50 ms
    private static let minimumChunkBytes = 1_600

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var eventsContinuation: AsyncStream<StreamingEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var pendingAudio = Data()
    private var lastCommittedTurnOrder: Int?
    private var didSendTerminate = false

    private(set) var transcriptionEvents: AsyncStream<StreamingEvent>

    init() {
        var continuation: AsyncStream<StreamingEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        eventsContinuation?.finish()
    }

    func connect(apiKey: String, model: String, language: String?, customVocabulary: [String] = []) async throws {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "AssemblyAIStreaming", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Missing AssemblyAI API key"
            ])
        }

        guard let url = Self.streamingURL(model: model, language: language, customVocabulary: customVocabulary) else {
            throw NSError(domain: "AssemblyAIStreaming", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Model \(model) does not support streaming"
            ])
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        pendingAudio.removeAll(keepingCapacity: true)
        lastCommittedTurnOrder = nil
        didSendTerminate = false
        task.resume()

        do {
            try await waitForBeginEvent(from: task)
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
            webSocketTask = nil
            urlSession = nil
            throw error
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let task = webSocketTask else {
            throw NSError(domain: "AssemblyAIStreaming", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Not connected to AssemblyAI streaming"
            ])
        }

        pendingAudio.append(data)
        while pendingAudio.count >= Self.minimumChunkBytes {
            let chunk = pendingAudio.prefix(Self.minimumChunkBytes)
            try await task.send(.data(Data(chunk)))
            pendingAudio.removeFirst(Self.minimumChunkBytes)
        }
    }

    func commit() async throws {
        guard let task = webSocketTask else {
            throw NSError(domain: "AssemblyAIStreaming", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Not connected to AssemblyAI streaming"
            ])
        }

        if !pendingAudio.isEmpty {
            try await task.send(.data(pendingAudio))
            pendingAudio.removeAll(keepingCapacity: true)
        }

        didSendTerminate = true
        try await task.send(.string(#"{"type":"Terminate"}"#))
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil

        if let task = webSocketTask {
            if !didSendTerminate {
                try? await task.send(.string(#"{"type":"Terminate"}"#))
            }
            task.cancel(with: .normalClosure, reason: nil)
        }

        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        eventsContinuation?.finish()
        pendingAudio.removeAll(keepingCapacity: false)
        lastCommittedTurnOrder = nil
        didSendTerminate = false
    }

    // MARK: - Private

    private static func streamingURL(model: String, language: String?, customVocabulary: [String]) -> URL? {
        guard model == "universal-3-5-pro" else {
            return nil
        }

        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")
        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "speech_model", value: "universal-3-5-pro"),
            URLQueryItem(name: "mode", value: "balanced")
        ]

        if let language,
           !language.isEmpty,
           language != "auto" {
            queryItems.append(URLQueryItem(name: "language_code", value: language))
        }

        let keyterms = normalizedKeyterms(customVocabulary)
        if !keyterms.isEmpty,
           let keytermsData = try? JSONSerialization.data(withJSONObject: keyterms),
           let keytermsJSON = String(data: keytermsData, encoding: .utf8) {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: keytermsJSON))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    private static func normalizedKeyterms(_ customVocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in customVocabulary {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = trimmed.split(separator: " ").count
            guard !trimmed.isEmpty, trimmed.count <= 50, wordCount <= 6 else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
            if result.count == keytermLimit { break }
        }
        return result
    }

    private func waitForBeginEvent(from task: URLSessionWebSocketTask) async throws {
        do {
            while true {
                let message = try await task.receive()
                let text: String?
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    text = String(data: data, encoding: .utf8)
                @unknown default:
                    text = nil
                }

                guard let text,
                      let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let error = json["error"] as? String {
                    throw NSError(domain: "AssemblyAIStreaming", code: 400, userInfo: [
                        NSLocalizedDescriptionKey: error
                    ])
                }

                if json["type"] as? String == "Begin" {
                    eventsContinuation?.yield(.sessionStarted)
                    return
                }

                handleMessage(json)
            }
        } catch let error as NSError where error.domain == "AssemblyAIStreaming" {
            throw error
        } catch {
            throw NSError(domain: "AssemblyAIStreaming", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to start AssemblyAI streaming session: \(error.localizedDescription)"
            ])
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    eventsContinuation?.yield(.error(error.localizedDescription))
                }
                break
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        handleMessage(json)
    }

    private func handleMessage(_ json: [String: Any]) {
        if let error = json["error"] as? String {
            eventsContinuation?.yield(.error(error))
            return
        }

        guard let type = json["type"] as? String else { return }
        switch type {
        case "Turn":
            handleTurn(json)
        case "Termination":
            eventsContinuation?.yield(.committed(text: ""))
        default:
            break
        }
    }

    private func handleTurn(_ json: [String: Any]) {
        let transcript = (json["transcript"] as? String) ?? ""
        guard !transcript.isEmpty else { return }

        let endOfTurn = (json["end_of_turn"] as? Bool) ?? false
        let turnIsFormatted = (json["turn_is_formatted"] as? Bool) ?? false
        let turnOrder = json["turn_order"] as? Int

        if endOfTurn && (turnIsFormatted || lastCommittedTurnOrder != turnOrder) {
            eventsContinuation?.yield(.committed(text: transcript))
            lastCommittedTurnOrder = turnOrder
        } else if !endOfTurn {
            eventsContinuation?.yield(.partial(text: transcript))
        }
    }
}
