import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Post-processes ASR transcription using Apple Foundation Models (on-device LLM).
/// Corrects punctuation and removes filler words while preserving meaning.
/// Requires macOS 26+ with Apple Intelligence enabled.
@available(macOS 26, *)
actor TextRefiner {
    static let shared = TextRefiner()

    private var session: LanguageModelSession?
    private init() {}

    func refine(_ text: String) async -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return text }

        // Verify Apple Intelligence is actually available on this device
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            logWarn("TextRefiner", "Apple Intelligence not available: \(availability)")
            return text
        }

        if session == nil { session = LanguageModelSession() }
        guard let session else { return text }

        let prompt = """
以下是語音辨識結果，句子缺少逗號等標點符號，請為它加上適當的逗號、句號、問號、驚嘆號，\
保持所有詞彙原封不動，直接輸出加完標點後的文字，不要任何說明或前言：
\(text)
"""
        let start = Date()
        do {
            let response = try await session.respond(to: prompt)
            let refined = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Date().timeIntervalSince(start)
            let ms = Int(elapsed * 1000)
            logInfo("TextRefiner", "Refined \(text.count)→\(refined.count) chars in \(ms)ms")
            return refined.isEmpty ? text : refined
        } catch {
            logWarn("TextRefiner", "Refinement failed, returning original: \(error.localizedDescription)")
            return text
        }
    }

    /// Eagerly initialise the LanguageModelSession so the first real transcription
    /// doesn't pay the cold-start penalty.
    func warmUp() async {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            logWarn("TextRefiner", "Skipping warm-up — Apple Intelligence not available: \(availability)")
            return
        }
        if session == nil {
            session = LanguageModelSession()
            logInfo("TextRefiner", "Session initialised (warm-up)")
        }
    }
}

#else

// Stub when FoundationModels SDK is unavailable
@available(macOS 26, *)
actor TextRefiner {
    static let shared = TextRefiner()
    private init() {}
    func refine(_ text: String) async -> String { text }
    func warmUp() async {}
}

#endif
