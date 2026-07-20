//
//  PostProcessingFailoverTests.swift
//  VoiceInk-iosTests
//

import Foundation
import Testing
@testable import VoiceInk_ios

struct PostProcessingFailoverTests {

    private func keys(_ available: Set<Provider>) -> (Provider) -> String {
        { available.contains($0) ? "key" : "" }
    }

    @Test func primaryComesFirst() {
        let candidates = PostProcessingFailover.candidates(
            primaryProvider: .gemini,
            primaryModel: "gemini-2.5-flash",
            fallbacks: [PostProcessingFallback(provider: .groq, model: "llama-3.1-8b-instant")],
            apiKeyLookup: keys([.gemini, .groq])
        )
        #expect(candidates == [
            PostProcessingCandidate(provider: .gemini, model: "gemini-2.5-flash"),
            PostProcessingCandidate(provider: .groq, model: "llama-3.1-8b-instant"),
        ])
    }

    @Test func duplicatesDropped() {
        let candidates = PostProcessingFailover.candidates(
            primaryProvider: .groq,
            primaryModel: "llama-3.1-8b-instant",
            fallbacks: [
                PostProcessingFallback(provider: .groq, model: "llama-3.1-8b-instant"),
                PostProcessingFallback(provider: .groq, model: "llama-3.3-70b-versatile"),
            ],
            apiKeyLookup: keys([.groq])
        )
        #expect(candidates.count == 2)
        #expect(candidates[1].model == "llama-3.3-70b-versatile")
    }

    @Test func missingAPIKeyFiltered() {
        let candidates = PostProcessingFailover.candidates(
            primaryProvider: .gemini,
            primaryModel: "gemini-2.5-flash",
            fallbacks: [PostProcessingFallback(provider: .groq, model: "llama-3.1-8b-instant")],
            apiKeyLookup: keys([.gemini])
        )
        #expect(candidates == [PostProcessingCandidate(provider: .gemini, model: "gemini-2.5-flash")])
    }

    @Test func emptyModelFiltered() {
        let candidates = PostProcessingFailover.candidates(
            primaryProvider: .gemini,
            primaryModel: "gemini-2.5-flash",
            fallbacks: [PostProcessingFallback(provider: .groq, model: "")],
            apiKeyLookup: keys([.gemini, .groq])
        )
        #expect(candidates.count == 1)
    }

    @Test func httpErrorClassification() {
        func httpError(_ status: Int) -> NSError {
            NSError(domain: "LLMPostProcessing", code: status)
        }
        #expect(PostProcessingFailover.isTransient(httpError(429)))
        #expect(PostProcessingFailover.isTransient(httpError(500)))
        #expect(PostProcessingFailover.isTransient(httpError(503)))
        #expect(PostProcessingFailover.isTransient(httpError(404)))
        #expect(!PostProcessingFailover.isTransient(httpError(401)))
        #expect(!PostProcessingFailover.isTransient(httpError(400)))
    }

    @Test func urlErrorClassification() {
        func urlError(_ code: Int) -> NSError {
            NSError(domain: NSURLErrorDomain, code: code)
        }
        #expect(PostProcessingFailover.isTransient(urlError(NSURLErrorTimedOut)))
        #expect(PostProcessingFailover.isTransient(urlError(NSURLErrorNotConnectedToInternet)))
        #expect(!PostProcessingFailover.isTransient(urlError(NSURLErrorCancelled)))
    }

    @Test func nonNetworkErrorNotTransient() {
        struct SomeError: Error {}
        #expect(!PostProcessingFailover.isTransient(SomeError()))
    }
}
