//
//  StreamingSession.swift
//  VoiceInk-ios
//
//  Manages one streaming transcription lifecycle: buffers mic chunks from the
//  capture tap, sends them to AssemblyAI over the websocket while the user is
//  still speaking, and collects committed turns so the final text is ready
//  almost immediately at stop. Falls back to the batch upload path on any
//  failure (the WAV file is always written regardless).
//

import Foundation

/// Bridges audio chunks from the capture queue into an AsyncStream.
private final class AudioChunkSource: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(2_048)
        )
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func send(_ data: Data) {
        continuation.yield(data)
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
final class StreamingSession {

    enum StopResult {
        case finalized(text: String)
        case requiresBatchFallback
    }

    private enum State {
        case idle, connecting, streaming, committing, done, failed, cancelled
    }

    private let client = AssemblyAIStreamingClient()
    private let chunkSource = AudioChunkSource()
    private var sendTask: Task<Void, Never>?
    private var eventConsumerTask: Task<Void, Never>?
    private var state: State = .idle
    private var committedSegments: [String] = []
    private var commitSignal: AsyncStream<Void>.Continuation?

    var isStreaming: Bool { state == .streaming }

    func connect(apiKey: String, model: String, language: String?) async throws {
        state = .connecting
        committedSegments = []

        do {
            try await client.connect(apiKey: apiKey, model: model, language: language)
        } catch {
            state = .failed
            await client.disconnect()
            throw error
        }

        // cancel() may have been called while awaiting the connection
        if state == .cancelled {
            await client.disconnect()
            return
        }

        state = .streaming
        startSendLoop()
        startEventConsumer()
    }

    /// Safe to call from any thread (the capture queue). Chunks enqueued
    /// before the connection is up are buffered and sent once streaming starts.
    nonisolated func sendAudioChunk(_ data: Data) {
        chunkSource.send(data)
    }

    /// Drains buffered audio, sends the terminate commit, and waits (up to
    /// 10 s) for the final committed turn.
    func stopAndFinalize() async -> StopResult {
        guard state == .streaming else {
            cleanup()
            await client.disconnect()
            return .requiresBatchFallback
        }

        state = .committing

        // Finish the source so the send loop drains the tail and exits
        chunkSource.finish()
        await sendTask?.value
        sendTask = nil

        let (signalStream, signalContinuation) = AsyncStream.makeStream(of: Void.self)
        commitSignal = signalContinuation

        do {
            try await client.commit()
        } catch {
            print("⚠️ Streaming commit failed: \(error.localizedDescription)")
            commitSignal?.finish()
            commitSignal = nil
            state = .failed
            cleanup()
            await client.disconnect()
            return .requiresBatchFallback
        }

        let receivedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for await _ in signalStream {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        commitSignal?.finish()
        commitSignal = nil
        state = .done
        let finalText = committedSegments.joined(separator: " ")
        cleanup()
        await client.disconnect()

        if !receivedInTime && finalText.isEmpty {
            print("⚠️ Streaming produced no transcript before timeout")
            return .requiresBatchFallback
        }
        return .finalized(text: finalText)
    }

    func cancel() {
        state = .cancelled
        cleanup()
        Task { await client.disconnect() }
        committedSegments = []
    }

    // MARK: - Private

    private func startSendLoop() {
        let source = chunkSource
        let client = client

        sendTask = Task.detached {
            for await chunk in source.stream {
                do {
                    try await client.sendAudioChunk(chunk)
                } catch {
                    print("⚠️ Streaming chunk send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startEventConsumer() {
        let events = client.transcriptionEvents

        eventConsumerTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                switch event {
                case .committed(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.committedSegments.append(trimmed)
                    }
                    if self.state == .committing {
                        self.commitSignal?.yield()
                    }
                case .partial, .sessionStarted:
                    break
                case .error(let message):
                    print("⚠️ Streaming event error: \(message)")
                }
            }
        }
    }

    private func cleanup() {
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        chunkSource.finish()
        commitSignal?.finish()
        commitSignal = nil
    }
}
