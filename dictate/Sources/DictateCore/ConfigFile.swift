import Foundation

/// Subset reader for the shared dictation config.
/// Double-quoted strings, full-line comments, and `#` outside strings.
public struct ServiceConfig: Equatable {
    public var sttBaseURL: String
    public var sttModel: String
    public var sttLanguage: String
    public var llmBaseURL: String
    public var llmModel: String
    public var llmReasoningEffort: String
    public var hotkey: HotkeySpec
    public var replacements: [(String, String)]
    public var debugEnabled: Bool

    public static func == (lhs: ServiceConfig, rhs: ServiceConfig) -> Bool {
        lhs.sttBaseURL == rhs.sttBaseURL
            && lhs.sttModel == rhs.sttModel
            && lhs.sttLanguage == rhs.sttLanguage
            && lhs.llmBaseURL == rhs.llmBaseURL
            && lhs.llmModel == rhs.llmModel
            && lhs.llmReasoningEffort == rhs.llmReasoningEffort
            && lhs.hotkey == rhs.hotkey
            && lhs.replacements.elementsEqual(rhs.replacements, by: ==)
            && lhs.debugEnabled == rhs.debugEnabled
    }
}

public struct ConfigReadError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum ConfigFile {
    public static func parse(_ text: String) throws -> ServiceConfig {
        var sections: [String: [String: String]] = [:]
        var replacementPairs: [(String, String)] = []
        var current: String?
        var sawReplacements = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), line.count > 2 else {
                    throw ConfigReadError("bad section header: \(line)")
                }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if sections[name] != nil || (name == "replacements" && sawReplacements) {
                    throw ConfigReadError("duplicate section [\(name)]")
                }
                current = name
                if name == "replacements" {
                    sawReplacements = true
                } else {
                    sections[name] = [:]
                }
                continue
            }
            guard let section = current else {
                throw ConfigReadError("key outside a section: \(line)")
            }
            let (key, value) = try splitAssignment(line)
            if section == "replacements" {
                if key.isEmpty { throw ConfigReadError("replacement key is empty") }
                replacementPairs.append((key, value))
            } else {
                var table = sections[section] ?? [:]
                if table[key] != nil { throw ConfigReadError("duplicate key \(section).\(key)") }
                table[key] = value
                sections[section] = table
            }
        }

        for name in sections.keys where !["stt", "llm", "hotkey", "debug"].contains(name) {
            throw ConfigReadError("unknown section: \(name)")
        }

        let stt = try require("stt", in: sections)
        let llm = try require("llm", in: sections)
        let hotkeyTable = try require("hotkey", in: sections)
        if !sawReplacements { throw ConfigReadError("missing section: replacements") }

        try exactKeys("stt", stt, ["base_url", "language", "model"])
        try exactKeys("llm", llm, ["base_url", "model", "reasoning_effort"])
        try exactKeys("hotkey", hotkeyTable, ["key", "mode"])
        if let debug = sections["debug"] {
            try exactKeys("debug", debug, ["enabled"])
        }

        let hotkeyName = try field("hotkey.key", hotkeyTable, "key")
        guard let hotkey = HotkeySpec.named(hotkeyName) else {
            throw ConfigReadError("hotkey.key must be a known hold key, got \(hotkeyName)")
        }
        let mode = try field("hotkey.mode", hotkeyTable, "mode")
        if mode != "hold" { throw ConfigReadError("hotkey.mode must be hold") }

        let effort = try field("llm.reasoning_effort", llm, "reasoning_effort")
        let allowedEfforts = ["", "none", "minimal", "low", "medium", "high"]
        if !allowedEfforts.contains(effort) {
            throw ConfigReadError("llm.reasoning_effort is not a known value")
        }

        return ServiceConfig(
            sttBaseURL: try localURL("stt.base_url", try field("stt.base_url", stt, "base_url")),
            sttModel: try absolutePath(try field("stt.model", stt, "model")),
            sttLanguage: try language(try field("stt.language", stt, "language")),
            llmBaseURL: try localURL("llm.base_url", try field("llm.base_url", llm, "base_url")),
            llmModel: try nonempty("llm.model", try field("llm.model", llm, "model")),
            llmReasoningEffort: effort,
            hotkey: hotkey,
            replacements: replacementPairs,
            debugEnabled: try debugFlag(sections["debug"])
        )
    }

    private static func require(_ name: String, in sections: [String: [String: String]]) throws -> [String: String] {
        guard let table = sections[name] else { throw ConfigReadError("missing section: \(name)") }
        return table
    }

    private static func exactKeys(_ section: String, _ table: [String: String], _ allowed: [String]) throws {
        let extra = Set(table.keys).subtracting(allowed)
        if let name = extra.sorted().first {
            throw ConfigReadError("unknown key in [\(section)]: \(name)")
        }
    }

    private static func field(_ label: String, _ table: [String: String], _ key: String) throws -> String {
        guard let value = table[key] else { throw ConfigReadError("\(label) is missing") }
        return value
    }

    private static func nonempty(_ label: String, _ value: String) throws -> String {
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConfigReadError("\(label) is empty")
        }
        return value
    }

    private static func absolutePath(_ value: String) throws -> String {
        let path = try nonempty("stt.model", value)
        if !path.hasPrefix("/") { throw ConfigReadError("stt.model must be an absolute path") }
        return path
    }

    private static func language(_ value: String) throws -> String {
        let code = try nonempty("stt.language", value)
        if code.count > 8 || code.contains(where: { $0.isWhitespace }) {
            throw ConfigReadError("stt.language must be a short code such as en")
        }
        return code
    }

    private static func localURL(_ label: String, _ value: String) throws -> String {
        let trimmed = try nonempty(label, value).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let parts = URL(string: trimmed), parts.scheme == "http", let host = parts.host, let port = parts.port else {
            throw ConfigReadError("\(label) must be http://127.0.0.1:<port> or http://localhost:<port>")
        }
        if host != "127.0.0.1" && host != "localhost" {
            throw ConfigReadError("\(label) must stay on this machine")
        }
        if parts.user != nil { throw ConfigReadError("\(label) must not carry credentials") }
        _ = port
        return trimmed
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

    private static func debugFlag(_ table: [String: String]?) throws -> Bool {
        guard let table else { return false }
        guard let value = table["enabled"] else { throw ConfigReadError("[debug] missing: enabled") }
        if value == "true" { return true }
        if value == "false" { return false }
        throw ConfigReadError("debug.enabled must be true or false")
    }

    private static func parseValue(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "true" || trimmed == "false" { return trimmed }
        guard trimmed.hasPrefix("\"") else {
            throw ConfigReadError("values must be double-quoted strings")
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
