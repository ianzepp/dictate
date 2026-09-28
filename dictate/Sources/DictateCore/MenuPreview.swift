public enum MenuPreview {
    /// Two lines at `width` characters. A longer transcript ends the second line with an ellipsis.
    public static func lines(_ text: String, width: Int = 46) -> [String] {
        let limit = max(8, width)
        let flat = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.isEmpty { return [] }
        var remaining = Array(flat)
        let first = take(&remaining, maxChars: limit)
        if remaining.isEmpty { return [first] }
        if remaining.count <= limit {
            return [first, String(remaining)]
        }
        let second = take(&remaining, maxChars: limit - 1).trimmingCharacters(in: .whitespaces)
        return [first, second + "…"]
    }

    private static func take(_ remaining: inout [Character], maxChars: Int) -> String {
        if remaining.isEmpty || maxChars <= 0 { return "" }
        if remaining.count <= maxChars {
            let line = String(remaining)
            remaining.removeAll()
            return line
        }
        let window = remaining.prefix(maxChars)
        if let space = window.lastIndex(of: " "), space > window.startIndex {
            let count = remaining.distance(from: remaining.startIndex, to: space)
            let line = String(remaining.prefix(count))
            remaining.removeFirst(count)
            while remaining.first == " " { remaining.removeFirst() }
            return line
        }
        let line = String(window)
        remaining.removeFirst(maxChars)
        return line
    }
}
