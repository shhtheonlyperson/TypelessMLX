import Foundation

/// Manages a user-defined vocabulary list that is injected into the Whisper initial_prompt
/// to bias recognition toward domain-specific terms (proper nouns, abbreviations, etc.).
class DictionaryService {
    static let shared = DictionaryService()
    private init() {}

    private let key = "userDictionary"

    var rawTerms: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var terms: [String] {
        rawTerms.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Builds the final Whisper prompt by appending dictionary terms to the user's base prompt.
    /// Total result is capped at 600 characters to stay within Whisper's prompt limit.
    func buildPrompt(basePrompt: String) -> String {
        let dictPart = terms.prefix(40).joined(separator: "、")
        if dictPart.isEmpty { return basePrompt }
        let combined = basePrompt.isEmpty ? dictPart : "\(basePrompt) \(dictPart)"
        return String(combined.prefix(600))
    }
}
