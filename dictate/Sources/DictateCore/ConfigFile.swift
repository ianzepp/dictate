import Foundation

/// What the menu-bar app needs from the shared config: where the speech service
/// listens, the hold key, and the debug switch. The speech service validates the
/// rest, so sections and keys this reader does not use are skipped unread.
public struct ServiceConfig: Equatable {
    public var speechPort: Int
    public var hotkey: HotkeySpec
    /// Pressed during a hold, keeps recording after the hold key is let go.
    public var lockKey: HotkeySpec?
    public var debugEnabled: Bool

    public var serviceURL: String { "http://127.0.0.1:\(speechPort)" }
}

public struct ConfigReadError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum ConfigFile {
    /// The same default as the speech service.
    public static let defaultSpeechPort = 8090
    private static let read: [String: Set<String>] = [
        "speech": ["port"],
        "hotkey": ["key", "mode", "lock"],
        "debug": ["enabled"],
    ]

    public static func parse(_ text: String) throws -> ServiceConfig {
        var values: [String: String] = [:]
        var current: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), line.count > 2 else {
                    throw ConfigReadError("bad section header: \(line)")
                }
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let section = current, let keys = read[section] else { continue }
            let (key, value) = try splitAssignment(line)
            if keys.contains(key) { values["\(section).\(key)"] = value }
        }

        let hotkeyName = values["hotkey.key"] ?? "fn"
        guard let hotkey = HotkeySpec.named(hotkeyName) else {
            throw ConfigReadError("hotkey.key must be a known hold key, got \(hotkeyName)")
        }
        if let mode = values["hotkey.mode"], mode != "hold" {
            throw ConfigReadError("hotkey.mode must be hold")
        }
        // The default steps aside when the hold key is itself right_option.
        let lockName = values["hotkey.lock"] ?? (hotkeyName == "right_option" ? "none" : "right_option")
        var lockKey: HotkeySpec?
        if lockName != "none" {
            guard let spec = HotkeySpec.named(lockName), lockName != hotkeyName else {
                throw ConfigReadError("hotkey.lock must be none or a hold key other than hotkey.key")
            }
            lockKey = spec
        }
        return ServiceConfig(
            speechPort: try port(values["speech.port"]),
            hotkey: hotkey,
            lockKey: lockKey,
            debugEnabled: try flag("debug.enabled", values["debug.enabled"])
        )
    }

    private static func port(_ value: String?) throws -> Int {
        guard let value else { return defaultSpeechPort }
        guard let port = Int(value), (1024...65535).contains(port) else {
            throw ConfigReadError("speech.port must be a number between 1024 and 65535")
        }
        return port
    }

    private static func flag(_ label: String, _ value: String?) throws -> Bool {
        switch value {
        case nil, "false": return false
        case "true": return true
        default: throw ConfigReadError("\(label) must be true or false")
        }
    }

    private static func splitAssignment(_ line: String) throws -> (String, String) {
        var inString = false
        var escaped = false
        let chars = Array(line)
        for index in chars.indices {
            let char = chars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            if char == "\"" {
                inString = true
                continue
            }
            if char == "#" { break }
            if char == "=" {
                let key = try parseKey(String(chars[..<index]))
                let rawValue = String(chars[chars.index(after: index)...])
                let value = try parseValue(stripComment(rawValue))
                return (key, value)
            }
        }
        throw ConfigReadError("expected key = value: \(line)")
    }

    private static func stripComment(_ text: String) -> String {
        var inString = false
        var escaped = false
        var kept = ""
        for char in text {
            if inString {
                kept.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            if char == "\"" {
                inString = true
                kept.append(char)
                continue
            }
            if char == "#" { break }
            kept.append(char)
        }
        return kept.trimmingCharacters(in: .whitespaces)
    }

    private static func parseKey(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") {
            var index = trimmed.startIndex
            return try parseQuoted(trimmed, at: &index)
        }
        if trimmed.isEmpty || trimmed.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }) {
            throw ConfigReadError("bad key \(trimmed)")
        }
        return trimmed
    }

    private static func parseValue(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "true" || trimmed == "false" { return trimmed }
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) { return trimmed }
        guard trimmed.hasPrefix("\"") else {
            throw ConfigReadError("values must be quoted strings, numbers, or true/false")
        }
        var index = trimmed.startIndex
        let value = try parseQuoted(trimmed, at: &index)
        let rest = trimmed[index...].trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { throw ConfigReadError("trailing junk after value") }
        return value
    }

    private static func parseQuoted(_ text: String, at index: inout String.Index) throws -> String {
        guard index < text.endIndex, text[index] == "\"" else {
            throw ConfigReadError("expected a quoted string")
        }
        index = text.index(after: index)
        var out = ""
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if char == "\\" {
                guard index < text.endIndex else { throw ConfigReadError("bad escape") }
                let escaped = text[index]
                index = text.index(after: index)
                switch escaped {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: throw ConfigReadError("unsupported escape \\\(escaped)")
                }
                continue
            }
            if char == "\"" { return out }
            out.append(char)
        }
        throw ConfigReadError("unterminated string")
    }
}
