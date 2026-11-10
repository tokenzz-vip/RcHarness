import Foundation

enum PhraseSearch {
    static func filter(_ phrases: [SavedPhrase], query: String) -> [SavedPhrase] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return phrases }
        return phrases.filter { phrase in
            let fields = [phrase.title, phrase.text, phrase.englishTitle, phrase.englishText].map(normalize)
            return terms.allSatisfy { term in fields.contains { matches(term, in: $0) } }
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func matches(_ term: String, in text: String) -> Bool {
        var remaining = term[...]
        for character in text {
            if character == remaining.first { remaining.removeFirst() }
            if remaining.isEmpty { return true }
        }
        return false
    }
}
