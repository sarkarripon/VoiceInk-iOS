//
//  PostProcessingFailover.swift
//  VoiceInk-ios
//
//  Pure helpers for post-processing model failover: candidate ordering and
//  error classification. Mirrors the Mac app's EnhancementFailover, but
//  candidates are cross-provider pairs and there is a single pass — no
//  retry cycles, which don't fit the iOS background execution window.
//

import Foundation

struct PostProcessingCandidate: Equatable {
    let provider: Provider
    let model: String
}

enum PostProcessingFailover {

    /// Models to try in order: primary first, then fallbacks. Duplicates and
    /// pairs whose provider has no API key are dropped.
    static func candidates(
        primaryProvider: Provider,
        primaryModel: String,
        fallbacks: [PostProcessingFallback],
        apiKeyLookup: (Provider) -> String
    ) -> [PostProcessingCandidate] {
        var result: [PostProcessingCandidate] = []

        func append(_ provider: Provider, _ model: String) {
            let candidate = PostProcessingCandidate(provider: provider, model: model)
            guard !model.isEmpty,
                  !result.contains(candidate),
                  !apiKeyLookup(provider).isEmpty else { return }
            result.append(candidate)
        }

        append(primaryProvider, primaryModel)
        for fallback in fallbacks {
            append(fallback.provider, fallback.model)
        }
        return result
    }

    /// Whether an error should advance to the next fallback model.
    /// Transient: network problems, timeouts, rate limits, server errors,
    /// unknown model. Not transient: auth/config errors — the same key or
    /// prompt would fail everywhere, so abort the chain.
    static func isTransient(_ error: Error) -> Bool {
        // URLSession throws URLError directly; check it before NSError bridging
        if let urlError = error as? URLError {
            return transientURLErrorCodes.contains(urlError.code.rawValue)
        }

        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            return transientURLErrorCodes.contains(nsError.code)
        }

        // OpenAICompatibleClient throws NSError(domain: "LLMPostProcessing",
        // code: <HTTP status>)
        if nsError.domain == "LLMPostProcessing" {
            let status = nsError.code
            return status == 429 || status == 404 || status == 408 || (500...599).contains(status)
        }

        return false
    }

    private static let transientURLErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
    ]
}
