# Post-Processing Fallback Models — Design

Date: 2026-07-20. Approved by user in-session.

## Problem

Post-processing uses a single LLM provider+model. When that model is degraded
(e.g. Gemini 503 "high demand", request timeouts), the keyboard flow waits the
full 60s default timeout and the app is often suspended mid-request by the
30s background hibernate, leaving the keyboard stuck on "Transcribing...".
Mac VoiceInk already has same-provider fallback models (`aiModelFallbacks` +
`EnhancementFailover`); iOS has nothing.

## Decisions (user-approved)

- Fallbacks are **provider+model pairs** (not same-provider-only like Mac) so
  a whole-provider outage can be survived.
- **Single pass** through candidates, **15s per-request timeout**, no retry
  cycles or backoff (Mac's 3-cycle exponential backoff can run minutes and
  does not fit the iOS 30s background window).

## Components

1. **`PostProcessingFallback`** (Codable, Hashable, Identifiable):
   `provider: Provider`, `model: String`. New field
   `Mode.postProcessingFallbacks: [PostProcessingFallback]?` — optional with
   synthesized Codable, so modes stored before this field decode as nil;
   read sites coalesce with `?? []`.
2. **`PostProcessingFailover`** (pure helper, mirrors Mac naming):
   - `candidates(primaryProvider:primaryModel:fallbacks:apiKeyLookup:)` —
     primary first, then fallbacks; dedup; drop pairs with an empty model or
     whose provider has no API key.
   - `isTransient(_:)` — network errors, timeout, HTTP 429/5xx/404/408
     advance to next candidate; other errors (e.g. 401 bad key) abort the
     chain.
3. **`LLMPostProcessor.postProcessTranscript(candidates:...)`** — loops the
   chain, one attempt per candidate, 15s timeout, returns
   `(text: String, used: PostProcessingCandidate)` on first success.
   `OpenAICompatibleClient` surfaces HTTP status codes for classification.
4. **Call sites** — `RecordingManager` and `TranscriptionRetryService` build
   the candidate list from mode settings; winning model saved to
   `note.aiEnhancementModelName`.
5. **Hibernate guard** — `BackgroundKeepAliveService` idle timer re-arms while
   the transcription/post-processing pipeline is in flight (previously only
   while mic capturing). Without this the chain freezes on suspension. The
   `isProcessing` flag has a 120s staleness cutoff, so a wedged pipeline can
   never block hibernate forever.
6. **UI** — `ModeConfigurationView` post-processing section gains "Fallback
   models": up to 3 rows, provider + model pickers (reuses dynamic model
   lists; the VoiceInk provider shows its fixed model instead), swipe to
   delete.

## Error handling

- Non-transient error aborts the chain immediately.
- All candidates fail → raw transcript is still delivered (existing behavior).

## Testing

Unit tests for `PostProcessingFailover`: candidate ordering, dedup, API-key
filtering, transient classification. Pure functions, no network.
