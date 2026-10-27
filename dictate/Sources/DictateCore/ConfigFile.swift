import Foundation

public struct Replacement: Equatable, Sendable, Codable {
    public var source: String
    public var replacement: String

    public init(source: String, replacement: String) {
        self.source = source
        self.replacement = replacement
    }
}

public struct AppConfig: Equatable, Sendable {
    public var speechModel: String
    public var speechLanguage: String
    public var cleanupEnabled: Bool
    public var cleanupModel: String
    public var cleanupURL: String
    public var cleanupName: String
    public var cleanupReasoningEffort: String
    public var hotkey: HotkeySpec
    /// Pressed during a hold to keep recording after the hold key is released.
    public var lockKey: HotkeySpec?
    public var debugEnabled: Bool
    /// Replacement order is the same as the order in the config file.
    public var replacements: [Replacement]
}

public struct ConfigReadError: Error, Equatable, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum ConfigFile {
    fileprivate static let keys: [String: Set<String>] = [
        "speech": ["model", "language"],
        "cleanup": ["enabled", "model", "url", "name", "reasoning_effort"],
        "hotkey": ["key", "mode", "lock"],
        "debug": ["enabled"],
        "replacements": [],
    ]
    private static let hotkeyNames = [
        "fn", "right_option", "left_option", "right_command", "left_command", "right_control", "right_shift",
    ]
    private static let reasoningEfforts = ["", "none", "minimal", "low", "medium", "high"]

    /// Parse the strict, documented subset of TOML used by Dictate's config.
    /// Tables are single-level, values are single-line basic strings, booleans,
    /// or numbers, and comments are supported. Other TOML forms fail explicitly.
    public static func parse(_ text: String) throws -> AppConfig {
        var parser = ConfigParser(text: text)
        let parsed = try parser.parse()
        let speech = parsed.tables["speech"] ?? [:]
        guard speech["model"] != nil else {
            throw ConfigReadError("[speech] missing: model")
        }

        let speechModel = try model("speech.model", string(speech["model"], label: "speech.model", default: ""))
        let language = try string(speech["language"], label: "speech.language", default: "en")
        if language.isEmpty || language.unicodeScalars.count > 8 || language.contains(where: { $0.isWhitespace }) {
            throw ConfigReadError("speech.language must be a short code such as en")
        }

        let cleanup = parsed.tables["cleanup"] ?? [:]
        let enabled = try boolean(cleanup["enabled"], label: "cleanup.enabled", default: true)
        var cleanupModel = try string(cleanup["model"], label: "cleanup.model", default: "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        var cleanupURL = try string(cleanup["url"], label: "cleanup.url", default: "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        var cleanupName = try string(cleanup["name"], label: "cleanup.name", default: "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let effort = try string(cleanup["reasoning_effort"], label: "cleanup.reasoning_effort", default: "")
        guard reasoningEfforts.contains(effort) else {
            throw ConfigReadError("cleanup.reasoning_effort must be one of \"\", none, minimal, low, medium, high")
        }

        if !enabled {
            cleanupModel = ""
            cleanupURL = ""
            cleanupName = ""
        } else if !cleanupModel.isEmpty && (!cleanupURL.isEmpty || !cleanupName.isEmpty) {
            throw ConfigReadError("[cleanup] takes either model, or url and name, not both")
        } else if !cleanupModel.isEmpty {
            cleanupModel = try model("cleanup.model", cleanupModel)
        } else if !cleanupURL.isEmpty && !cleanupName.isEmpty {
            cleanupURL = try localURL("cleanup.url", cleanupURL)
        } else {
            throw ConfigReadError("[cleanup] needs model, or url and name, or enabled = false")
        }

        let hotkey = parsed.tables["hotkey"] ?? [:]
        let hotkeyName = try string(hotkey["key"], label: "hotkey.key", default: "fn")
        guard let hotkeySpec = HotkeySpec.named(hotkeyName) else {
            throw ConfigReadError("hotkey.key must be one of \(hotkeyNames.joined(separator: ", "))")
        }
        let mode = try string(hotkey["mode"], label: "hotkey.mode", default: "hold")
        guard mode == "hold" else { throw ConfigReadError("hotkey.mode must be hold") }

        let defaultLock = hotkeyName == "right_option" ? "none" : "right_option"
        let lockName = try string(hotkey["lock"], label: "hotkey.lock", default: defaultLock)
        let lockKey: HotkeySpec?
        if lockName == "none" {
            lockKey = nil
        } else if let spec = HotkeySpec.named(lockName), lockName != hotkeyName {
            lockKey = spec
        } else {
            throw ConfigReadError(
                "hotkey.lock must be none or one of \(hotkeyNames.joined(separator: ", ")) and differ from hotkey.key")
        }

        let debug = parsed.tables["debug"] ?? [:]
        return AppConfig(
            speechModel: speechModel,
            speechLanguage: language,
            cleanupEnabled: enabled,
            cleanupModel: cleanupModel,
            cleanupURL: cleanupURL,
            cleanupName: cleanupName,
            cleanupReasoningEffort: effort,
            hotkey: hotkeySpec,
            lockKey: lockKey,
            debugEnabled: try boolean(debug["enabled"], label: "debug.enabled", default: false),
            replacements: parsed.replacements
        )
    }

    private static func string(_ value: ConfigValue?, label: String, default fallback: String) throws -> String {
        guard let value else { return fallback }
        guard case .string(let text) = value else {
            throw ConfigReadError(typeError(label, expected: "a string", value: value))
        }
        return text
    }

    private static func boolean(_ value: ConfigValue?, label: String, default fallback: Bool) throws -> Bool {
        guard let value else { return fallback }
        guard case .boolean(let flag) = value else {
            throw ConfigReadError(typeError(label, expected: "true or false", value: value))
        }
        return flag
    }

    private static func typeError(_ label: String, expected: String, value: ConfigValue) -> String {
        switch value {
        case .string, .boolean, .number:
            return "\(label) must be \(expected)"
        case .unsupported(let kind):
            return "\(label) must be \(expected); \(kind) are not supported in Dictate config"
        }
    }

    private static func model(_ label: String, _ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ConfigReadError("\(label) is empty") }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") {
            let expanded = (value as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw ConfigReadError("\(label) path must be absolute or start with ~/")
            }
            return expanded
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, !value.hasSuffix("/"), !value.contains(":") else {
            throw ConfigReadError("\(label) must be a path or a Hugging Face name such as owner/repo")
        }
        return value
    }

    private static func localURL(_ label: String, _ value: String) throws -> String {
        var value = value
        while value.hasSuffix("/") { value.removeLast() }
        guard
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "http",
            let host = components.host?.lowercased(),
            host == "127.0.0.1" || host == "localhost",
            let port = components.port,
            (1...65535).contains(port),
            components.query == nil, components.fragment == nil
        else {
            throw ConfigReadError("\(label) must be a loopback HTTP base URL with a port and no query or fragment")
        }
        guard components.user == nil && components.password == nil else {
            throw ConfigReadError("\(label) must not carry credentials")
        }
        return value
    }
}

private enum ConfigValue {
    case string(String)
    case boolean(Bool)
    case number
    case unsupported(String)
}

private struct ParsedConfig {
    var tables: [String: [String: ConfigValue]] = [:]
    var replacements: [Replacement] = []
}

private struct ConfigParser {
    private let lines: [String]
    private var config = ParsedConfig()
    private var currentTable: String?
    private var seenTables: Set<String> = []
    private var seenKeys: [String: Set<String>] = [:]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    mutating func parse() throws -> ParsedConfig {
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let uncommented = Self.stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if uncommented.isEmpty { continue }
            if uncommented.hasPrefix("[[") {
                throw error("array tables are unsupported; use a single [section] table", line: lineNumber)
            }
            if uncommented.hasPrefix("[") {
                try parseTable(uncommented, line: lineNumber)
            } else {
                try parseAssignment(uncommented, line: lineNumber)
            }
        }
        return config
    }

    private mutating func parseTable(_ line: String, line lineNumber: Int) throws {
        guard line.hasSuffix("]"), line.count >= 3 else {
            throw error("bad section header: \(line)", line: lineNumber)
        }
        let body = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if !body.hasPrefix("\"") && body.contains(".") {
            throw error("dotted table names are unsupported; Dictate sections use one name", line: lineNumber)
        }
        let name = try Self.parseKey(body, line: lineNumber)
        guard !name.contains(".") else {
            throw error("dotted table names are unsupported; Dictate sections use one name", line: lineNumber)
        }
        guard ConfigFile.keys[name] != nil else {
            throw error("unknown section: \(name)", line: lineNumber)
        }
        guard seenTables.insert(name).inserted else {
            throw error("duplicate table [\(name)]", line: lineNumber)
        }
        currentTable = name
    }

    private mutating func parseAssignment(_ line: String, line lineNumber: Int) throws {
        let (key, rawValue) = try Self.splitAssignment(line, line: lineNumber)
        guard let table = currentTable else {
            if ConfigFile.keys[key] != nil {
                throw error("\(key) must be declared as a [\(key)] table", line: lineNumber)
            }
            throw error("unknown section: \(key)", line: lineNumber)
        }
        if table == "speech" && key == "port" {
            throw error(
                "speech.port was removed; delete it from config.toml because speech inference now runs in the app",
                line: lineNumber)
        }
        guard let allowed = ConfigFile.keys[table], table == "replacements" || allowed.contains(key) else {
            throw error("unknown key in [\(table)]: \(key)", line: lineNumber)
        }
        guard seenKeys[table, default: []].insert(key).inserted else {
            throw error("duplicate key \(key) in [\(table)]", line: lineNumber)
        }

        let value = try Self.parseValue(rawValue, line: lineNumber)
        if table == "replacements" {
            guard !key.isEmpty else { throw error("replacement key must be a non-empty string", line: lineNumber) }
            guard case .string(let replacement) = value else {
                let detail: String
                if case .unsupported(let kind) = value {
                    detail = "; \(kind) are not supported in Dictate config"
                } else {
                    detail = ""
                }
                throw error("replacement for \(Self.repr(key)) must be a string\(detail)", line: lineNumber)
            }
            config.replacements.append(Replacement(source: key, replacement: replacement))
        } else {
            config.tables[table, default: [:]][key] = value
        }
    }

    private static func splitAssignment(_ line: String, line lineNumber: Int) throws -> (String, String) {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"" && escaped {
                    escaped = false
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                let keyText = String(line[..<index]).trimmingCharacters(in: .whitespaces)
                let key = try parseKey(keyText, line: lineNumber)
                let valueStart = line.index(after: index)
                return (key, String(line[valueStart...]).trimmingCharacters(in: .whitespaces))
            }
        }
        throw ConfigReadError("line \(lineNumber): expected key = value")
    }

    private static func parseKey(_ text: String, line lineNumber: Int) throws -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else {
            throw ConfigReadError("line \(lineNumber): key is empty")
        }
        if first == "'" {
            throw ConfigReadError("line \(lineNumber): single-quoted TOML strings are unsupported; use double quotes")
        }
        if first == "\"" {
            if text.hasPrefix("\"\"\"") {
                throw ConfigReadError("line \(lineNumber): multiline strings are unsupported; use a single-line string")
            }
            var index = text.startIndex
            let key = try parseBasicString(text, at: &index, line: lineNumber)
            let rest = text[index...].trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty else { throw ConfigReadError("line \(lineNumber): trailing junk after key") }
            return key
        }
        guard
            text.unicodeScalars.allSatisfy({ scalar in
                (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || (scalar.value >= 0x30 && scalar.value <= 0x39) || scalar.value == 0x5F || scalar.value == 0x2D
            })
        else {
            throw ConfigReadError("line \(lineNumber): bad key \(text); use a bare key or a quoted key")
        }
        return text
    }

    private static func parseValue(_ text: String, line lineNumber: Int) throws -> ConfigValue {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else {
            throw ConfigReadError("line \(lineNumber): expected a value")
        }
        if first == "'" {
            throw ConfigReadError("line \(lineNumber): single-quoted TOML strings are unsupported; use double quotes")
        }
        if first == "\"" {
            if text.hasPrefix("\"\"\"") {
                throw ConfigReadError("line \(lineNumber): multiline strings are unsupported; use a single-line string")
            }
            var index = text.startIndex
            let value = try parseBasicString(text, at: &index, line: lineNumber)
            guard text[index...].trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConfigReadError("line \(lineNumber): trailing junk after value")
            }
            return .string(value)
        }
        if text == "true" { return .boolean(true) }
        if text == "false" { return .boolean(false) }
        if isNumber(text) { return .number }
        if isDateTime(text) { return .unsupported("date/time values") }
        if first == "[" { return .unsupported("arrays") }
        if first == "{" { return .unsupported("inline tables") }
        if first.isNumber || first == "+" || first == "-" || text == "nan" || text == "inf" || text == "+inf"
            || text == "-inf"
        {
            throw ConfigReadError("line \(lineNumber): invalid TOML number or date/time value")
        }
        throw ConfigReadError("line \(lineNumber): unsupported bare value; use a quoted string, number, or true/false")
    }

    private static func parseBasicString(_ text: String, at index: inout String.Index, line lineNumber: Int) throws
        -> String
    {
        guard index < text.endIndex, text[index] == "\"" else {
            throw ConfigReadError("line \(lineNumber): expected a quoted string")
        }
        index = text.index(after: index)
        var output = ""
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\"" { return output }
            if character == "\\" {
                guard index < text.endIndex else {
                    throw ConfigReadError("line \(lineNumber): unterminated escape; multiline strings are unsupported")
                }
                let escaped = text[index]
                index = text.index(after: index)
                switch escaped {
                case "b": output.append("\u{0008}")
                case "t": output.append("\t")
                case "n": output.append("\n")
                case "f": output.append("\u{000C}")
                case "r": output.append("\r")
                case "\"": output.append("\"")
                case "\\": output.append("\\")
                case "u":
                    output.unicodeScalars.append(try parseUnicodeScalar(text, at: &index, digits: 4, line: lineNumber))
                case "U":
                    output.unicodeScalars.append(try parseUnicodeScalar(text, at: &index, digits: 8, line: lineNumber))
                default: throw ConfigReadError("line \(lineNumber): unsupported escape \\\(escaped)")
                }
                continue
            }
            guard let scalar = character.unicodeScalars.first, !isForbiddenControl(scalar.value) else {
                throw ConfigReadError("line \(lineNumber): control characters must use TOML escapes")
            }
            output.append(character)
        }
        throw ConfigReadError("line \(lineNumber): unterminated string")
    }

    private static func parseUnicodeScalar(
        _ text: String, at index: inout String.Index, digits: Int, line lineNumber: Int
    ) throws -> UnicodeScalar {
        var hex = ""
        for _ in 0..<digits {
            guard index < text.endIndex else { throw ConfigReadError("line \(lineNumber): incomplete Unicode escape") }
            let character = text[index]
            guard character.isHexDigit, character.isASCII else {
                throw ConfigReadError("line \(lineNumber): invalid Unicode escape")
            }
            hex.append(character)
            index = text.index(after: index)
        }
        guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else {
            throw ConfigReadError("line \(lineNumber): invalid Unicode scalar in escape")
        }
        return scalar
    }

    private static func isForbiddenControl(_ value: UInt32) -> Bool {
        (value < 0x20 && value != 0x09) || value == 0x7F
    }

    private static func isNumber(_ text: String) -> Bool {
        matches(text, pattern: #"[+-]?(?:0|[1-9](?:_?[0-9])*)"#)
            || matches(text, pattern: #"0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*"#)
            || matches(text, pattern: #"0o[0-7](?:_?[0-7])*"#) || matches(text, pattern: #"0b[01](?:_?[01])*"#)
            || matches(
                text,
                pattern:
                    #"[+-]?(?:(?:0|[1-9](?:_?[0-9])*)\.[0-9](?:_?[0-9])*(?:[eE][+-]?[0-9](?:_?[0-9])*)?|(?:0|[1-9](?:_?[0-9])*)[eE][+-]?[0-9](?:_?[0-9])*)"#
            ) || ["inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(text)
    }

    private static func isDateTime(_ text: String) -> Bool {
        matches(text, pattern: #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#)
            || matches(text, pattern: #"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?"#)
            || matches(
                text,
                pattern:
                    #"[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})?"#
            )
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        var result = ""
        for character in line {
            if let activeQuote = quote {
                result.append(character)
                if activeQuote == "\"" && escaped {
                    escaped = false
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "#" {
                break
            } else {
                result.append(character)
                if character == "\"" || character == "'" { quote = character }
            }
        }
        return result
    }

    private static func repr(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "\\'"))'"
    }

    private func error(_ message: String, line lineNumber: Int) -> ConfigReadError {
        ConfigReadError("line \(lineNumber): \(message)")
    }
}
