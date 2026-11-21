public enum AssistantHandle {
    public static func assign(_ items: [(id: String, name: String)]) -> [String: String] {
        var taken = Set<String>()
        var result: [String: String] = [:]
        result.reserveCapacity(items.count)

        for (id, name) in items {
            let base = baseHandle(id: id, name: name)
            var candidate = base
            if taken.contains(candidate) {
                var n = 2
                while true {
                    let suffix = "-\(n)"
                    var stem = String(base.prefix(max(0, 12 - suffix.count)))
                    while stem.hasSuffix("-") {
                        stem.removeLast()
                    }
                    let next = stem + suffix
                    if !taken.contains(next) {
                        candidate = next
                        break
                    }
                    n += 1
                }
            }
            taken.insert(candidate)
            result[id] = candidate
        }
        return result
    }

    private static func baseHandle(id: String, name: String) -> String {
        let words = extractWords(from: name)
        if words.isEmpty {
            let cleanID = id.lowercased().filter { $0 != "-" }
            let suffix = String(cleanID.prefix(4))
            return suffix.isEmpty ? "s" : "s-\(suffix)"
        }
        let shortened = words.prefix(2).map { $0.count > 6 ? String($0.prefix(4)) : $0 }
        var joined = String(shortened.joined(separator: "-").prefix(12))
        while joined.hasSuffix("-") {
            joined.removeLast()
        }
        return joined
    }

    private static func extractWords(from name: String) -> [String] {
        var rawTokens: [String] = []
        var current = ""
        for ch in name.lowercased() {
            if isWordChar(ch) {
                current.append(ch)
            } else if !current.isEmpty {
                rawTokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            rawTokens.append(current)
        }

        var words: [String] = []
        for token in rawTokens {
            if cyrillicStopwords.contains(token) { continue }
            var ascii = ""
            ascii.reserveCapacity(token.count)
            var hasCyrillic = false
            for ch in token {
                if let mapped = translitMap[ch] {
                    if ch != "'" && ch != "’" {
                        hasCyrillic = true
                    }
                    ascii.append(mapped)
                } else {
                    ascii.append(ch)
                }
            }
            if ascii.isEmpty { continue }
            if !hasCyrillic && latinStopwords.contains(ascii) { continue }
            words.append(ascii)
        }
        return words
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        if ch.isASCII && (ch.isLetter || ch.isNumber) {
            return true
        }
        return translitMap[ch] != nil
    }

    private static let cyrillicStopwords: Set<String> = [
        "за", "і", "й", "та", "в", "у", "на", "з", "із", "до", "для", "по",
    ]

    private static let latinStopwords: Set<String> = [
        "the", "a", "an", "of", "for", "to", "in", "on", "and",
    ]

    // Fixed table avoids ICU/Foundation applyingTransform so Linux and macOS match.
    private static let translitMap: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "e",
        "є": "ie", "ж": "zh", "з": "z", "и": "y", "і": "i", "ї": "i", "й": "i",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch",
        "ш": "sh", "щ": "shch", "ь": "", "ю": "iu", "я": "ia",
        "’": "", "'": "",
        "ё": "e", "ы": "y", "э": "e", "ъ": "",
    ]
}
