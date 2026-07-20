//
//  WhisperContextCache.swift
//  VoiceInk-ios
//
//  Keeps a loaded WhisperContext alive between transcriptions so the
//  model file read and Metal shader compilation are paid once, not on
//  every request.
//

import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

actor WhisperContextCache {
    static let shared = WhisperContextCache()

    private var loadTask: Task<WhisperContext, Error>?
    private var loadedPath: String?
    private var observerInstalled = false
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperContextCache")

    private init() {}

    /// Returns the cached context for `path`, loading it if needed.
    /// Concurrent callers share a single in-flight load.
    func context(for path: String) async throws -> WhisperContext {
        installMemoryWarningObserverIfNeeded()

        if loadedPath == path, let task = loadTask {
            if let context = try? await task.value {
                return context
            }
            // Previous load failed — clear and retry below
            loadTask = nil
            loadedPath = nil
        }

        // Different model requested — drop our reference to the old one.
        // WhisperContext.deinit frees the C context once in-flight callers
        // finish, so never call releaseResources here: another caller may
        // still be transcribing with it.
        let start = CFAbsoluteTimeGetCurrent()
        let task = Task { try await WhisperContext.createContext(path: path) }
        loadTask = task
        loadedPath = path

        do {
            let context = try await task.value
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            logger.info("Model loaded in \(Int(elapsed)) ms: \((path as NSString).lastPathComponent)")
            return context
        } catch {
            loadTask = nil
            loadedPath = nil
            logger.error("Model load failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Fire-and-forget warm-up, e.g. when recording starts.
    nonisolated func prewarm(path: String) {
        Task {
            _ = try? await self.context(for: path)
        }
    }

    /// Drops the cached context (memory warning, model deleted). The C
    /// context is freed by WhisperContext.deinit once any in-flight
    /// transcription holding it completes.
    func releaseAll() {
        if loadTask != nil {
            logger.info("Cached whisper context dropped")
        }
        loadTask = nil
        loadedPath = nil
    }

    private func installMemoryWarningObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await WhisperContextCache.shared.releaseAll() }
        }
        #endif
    }
}
