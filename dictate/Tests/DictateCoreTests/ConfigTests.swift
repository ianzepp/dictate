import DictateCore
import XCTest

final class ConfigTests: XCTestCase {
    func testCleanupEndpointRequiresAnUsableBaseURL() {
        for url in ["http://localhost:0/v1", "http://localhost:1234/v1?key=value", "http://localhost:1234/v1#fragment"]
        {
            let text = "[speech]\nmodel = \"a/b\"\n[cleanup]\nurl = \"\(url)\"\nname = \"qwen\"\n"
            XCTAssertThrowsError(try ConfigFile.parse(text), url)
        }
    }

    func testDocumentedNativeConfigSettings() throws {
        let config = try ConfigFile.parse(
            """
            [speech]
            model = "mlx-community/whisper-large-v3-turbo-4bit"
            language = "en"
            [cleanup]
            enabled = true
            model = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
            [hotkey]
            key = "fn"
            lock = "right_option"
            [debug]
            enabled = false
            [replacements]
            """)

        XCTAssertEqual(config.speechModel, "mlx-community/whisper-large-v3-turbo-4bit")
        XCTAssertEqual(config.speechLanguage, "en")
        XCTAssertTrue(config.cleanupEnabled)
        XCTAssertEqual(config.cleanupModel, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertEqual(config.cleanupURL, "")
        XCTAssertEqual(config.cleanupName, "")
        XCTAssertEqual(config.cleanupReasoningEffort, "")
        XCTAssertEqual(config.hotkey, HotkeySpec.named("fn"))
        XCTAssertEqual(config.hotkey.keyCode, 0x3F)
        XCTAssertEqual(config.hotkey.modifierBit, 1 << 23)
        XCTAssertEqual(config.lockKey, HotkeySpec.named("right_option"))
        XCTAssertFalse(config.debugEnabled)
        XCTAssertEqual(config.replacements, [])
    }

    func testSpeechModelIsRequiredAndSpeechPortHasMigrationError() {
        XCTAssertThrowsError(try ConfigFile.parse("[cleanup]\nenabled = false\n")) { error in
            XCTAssertTrue(String(describing: error).contains("[speech] missing: model"))
        }
        XCTAssertThrowsError(
            try ConfigFile.parse("[speech]\nmodel = \"owner/model\"\nport = 8090\n[cleanup]\nenabled = false\n")
        ) { error in
            XCTAssertTrue(String(describing: error).contains("speech.port was removed"))
            XCTAssertTrue(String(describing: error).contains("delete it"))
        }
    }

    func testDefaultsAndDisabledCleanupMatchPythonContract() throws {
        let config = try ConfigFile.parse(
            """
            [speech]
            model = "owner/model"

            [cleanup]
            enabled = false
            model = "  owner/ignored  "
            url = "http://example.com:1234/v1"
            name = "ignored"

            [hotkey]
            key = "right_option"
            """)

        XCTAssertEqual(config.speechLanguage, "en")
        XCTAssertFalse(config.cleanupEnabled)
        XCTAssertEqual(config.cleanupModel, "")
        XCTAssertEqual(config.cleanupURL, "")
        XCTAssertEqual(config.cleanupName, "")
        XCTAssertEqual(config.cleanupReasoningEffort, "")
        XCTAssertEqual(config.hotkey, HotkeySpec.named("right_option"))
        XCTAssertNil(config.lockKey)
        XCTAssertFalse(config.debugEnabled)
        XCTAssertEqual(config.replacements, [])
    }

    func testCleanupModelPathAndHuggingFaceName() throws {
        let path = try ConfigFile.parse(
            """
            [speech]
            model = "~/models/whisper"
            [cleanup]
            model = "~/models/qwen"
            """)
        XCTAssertEqual(path.speechModel, (NSHomeDirectory() as NSString).appendingPathComponent("models/whisper"))
        XCTAssertEqual(path.cleanupModel, (NSHomeDirectory() as NSString).appendingPathComponent("models/qwen"))

        let hub = try ConfigFile.parse(
            """
            [speech]
            model = "  owner/whisper  "
            [cleanup]
            model = " owner/qwen "
            """)
        XCTAssertEqual(hub.speechModel, "owner/whisper")
        XCTAssertEqual(hub.cleanupModel, "owner/qwen")
    }

    func testExternalCleanupServerAndReasoningEffort() throws {
        let config = try ConfigFile.parse(
            """
            [speech]
            model = "owner/model"
            [cleanup]
            url = "http://localhost:1234/v1///"
            name = "  qwen  "
            reasoning_effort = "none"
            """)

        XCTAssertTrue(config.cleanupEnabled)
        XCTAssertEqual(config.cleanupModel, "")
        XCTAssertEqual(config.cleanupURL, "http://localhost:1234/v1")
        XCTAssertEqual(config.cleanupName, "qwen")
        XCTAssertEqual(config.cleanupReasoningEffort, "none")
    }

    func testCleanupRequiresOneValidSource() {
        XCTAssertThrowsError(try ConfigFile.parse("[speech]\nmodel = \"a/b\"\n")) { error in
            XCTAssertTrue(String(describing: error).contains("enabled = false"))
        }

        let both = "[speech]\nmodel = \"a/b\"\n[cleanup]\nmodel = \"c/d\"\nurl = \"http://localhost:1\"\nname = \"x\"\n"
        XCTAssertThrowsError(try ConfigFile.parse(both))
        XCTAssertThrowsError(
            try ConfigFile.parse("[speech]\nmodel = \"a/b\"\n[cleanup]\nurl = \"http://localhost:1\"\n"))
        XCTAssertThrowsError(try ConfigFile.parse("[speech]\nmodel = \"a/b\"\n[cleanup]\nname = \"x\"\n"))
    }

    func testRejectsInvalidModelNamesAndPaths() {
        for value in ["whisper", "owner/", "owner/a/b", "owner/model:Q4", "./relative", "../relative"] {
            XCTAssertThrowsError(
                try ConfigFile.parse("[speech]\nmodel = \"\(value)\"\n[cleanup]\nenabled = false\n"), value)
        }
        XCTAssertThrowsError(try ConfigFile.parse("[speech]\nmodel = \"   \"\n[cleanup]\nenabled = false\n"))
    }

    func testRejectsBadLanguageAndCleanupEffort() {
        XCTAssertThrowsError(try parse("[speech]\nlanguage = \"\"\n"))
        XCTAssertThrowsError(try parse("[speech]\nlanguage = \"english long\"\n"))
        XCTAssertThrowsError(try parse("[cleanup]\nreasoning_effort = \"xhigh\"\n"))
    }

    func testRejectsRemoteOrCredentialedCleanupURLs() {
        for url in [
            "http://example.com:80/v1", "https://localhost:1234/v1", "http://localhost/v1", "http://localhost:99999/v1",
            "http://user:pass@localhost:1234/v1",
        ] {
            let text = "[speech]\nmodel = \"a/b\"\n[cleanup]\nurl = \"\(url)\"\nname = \"qwen\"\n"
            XCTAssertThrowsError(try ConfigFile.parse(text), url)
        }
    }

    func testHotkeyModesLocksAndDefaults() throws {
        let defaults = try parse("[hotkey]\nkey = \"fn\"\n")
        XCTAssertEqual(defaults.hotkey, HotkeySpec.named("fn"))
        XCTAssertEqual(defaults.lockKey, HotkeySpec.named("right_option"))

        let explicit = try parse("[hotkey]\nkey = \"right_option\"\nlock = \"right_command\"\n")
        XCTAssertEqual(explicit.hotkey, HotkeySpec.named("right_option"))
        XCTAssertEqual(explicit.lockKey, HotkeySpec.named("right_command"))
        XCTAssertNil(try parse("[hotkey]\nlock = \"none\"\n").lockKey)

        for text in [
            "[hotkey]\nkey = \"f13\"\n",
            "[hotkey]\nmode = \"toggle\"\n",
            "[hotkey]\nkey = \"right_option\"\nlock = \"right_option\"\n",
            "[hotkey]\nlock = \"f13\"\n",
        ] {
            XCTAssertThrowsError(try parse(text), text)
        }
    }

    func testReplacementOrderQuotedKeysAndUnicodeEscapes() throws {
        let config = try parse(
            """
            [replacements]
            "em el ex" = "MLX"
            "caf\\u00E9" = "café"
            "key\\U0001F680" = "🚀"
            "quote\\\"key" = "say \\\"hi\\\""
            "line\\tkey" = "first\\nsecond"
            "escaped-control" = "\\u0001"
            """)

        XCTAssertEqual(
            config.replacements,
            [
                Replacement(source: "em el ex", replacement: "MLX"),
                Replacement(source: "café", replacement: "café"),
                Replacement(source: "key🚀", replacement: "🚀"),
                Replacement(source: "quote\"key", replacement: "say \"hi\""),
                Replacement(source: "line\tkey", replacement: "first\nsecond"),
                Replacement(source: "escaped-control", replacement: "\u{0001}"),
            ])
        let encoded = try JSONEncoder().encode(config.replacements[0])
        XCTAssertEqual(try JSONDecoder().decode(Replacement.self, from: encoded), config.replacements[0])
    }

    func testRejectsEmptyDuplicateAndNonStringReplacements() {
        XCTAssertThrowsError(try parse("[replacements]\n\"\" = \"value\"\n"))
        XCTAssertThrowsError(try parse("[replacements]\nfoo = \"one\"\nfoo = \"two\"\n"))
        XCTAssertThrowsError(try parse("[replacements]\nfoo = true\n"))
        XCTAssertThrowsError(try parse("[replacements]\nfoo = [\"one\"]\n")) { error in
            XCTAssertTrue(String(describing: error).contains("arrays are not supported"))
        }
    }

    func testRejectsUnknownSectionsAndKeysEverywhere() {
        XCTAssertThrowsError(try parse("[future]\nkey = \"value\"\n")) { error in
            XCTAssertTrue(String(describing: error).contains("unknown section: future"))
        }
        for text in [
            "[speech]\nextra = \"x\"\n",
            "[cleanup]\nextra = \"x\"\n",
            "[hotkey]\nextra = \"x\"\n",
            "[debug]\nextra = \"x\"\n",
            "[cleanup]\nport = 8090\n",
        ] {
            XCTAssertThrowsError(try parse(text), text)
        }
        XCTAssertThrowsError(try ConfigFile.parse("unknown = \"x\"\n"))
    }

    func testRejectsDuplicateSectionsAndKeys() {
        XCTAssertThrowsError(try ConfigFile.parse("[speech]\nmodel = \"a/b\"\n[speech]\n")) { error in
            XCTAssertTrue(String(describing: error).contains("duplicate table"))
        }
        XCTAssertThrowsError(try parse("[hotkey]\nkey = \"fn\"\nkey = \"fn\"\n")) { error in
            XCTAssertTrue(String(describing: error).contains("duplicate key"))
        }
    }

    func testRejectsWrongTypesForEverySettingKind() {
        for text in [
            "[speech]\nmodel = true\n",
            "[speech]\nlanguage = 7\n",
            "[cleanup]\nenabled = \"false\"\n",
            "[cleanup]\nmodel = false\n",
            "[cleanup]\nurl = false\n",
            "[cleanup]\nname = false\n",
            "[cleanup]\nreasoning_effort = false\n",
            "[hotkey]\nkey = false\n",
            "[hotkey]\nmode = false\n",
            "[hotkey]\nlock = false\n",
            "[debug]\nenabled = \"yes\"\n",
        ] {
            XCTAssertThrowsError(try parse(text), text)
        }
        XCTAssertThrowsError(try parse("[cleanup]\nenabled = 1\n"))
    }

    func testRejectsMalformedOrUnsupportedTOMLPrecisely() {
        for (text, message) in [
            ("[speech]\nmodel = \"a/b\" trailing\n", "trailing junk after value"),
            ("[speech]\n\"model\" trailing = \"a/b\"\n", "trailing junk after key"),
            ("[speech]\nmodel = \"a/b\\q\"\n", "unsupported escape"),
            ("[speech]\nmodel = 'a/b'\n", "single-quoted TOML strings are unsupported"),
            ("[[speech]]\nmodel = \"a/b\"\n", "array tables are unsupported"),
            ("[speech]\nmodel = \"a/b\"\n[cleanup]\nmodel = [\"x\"]\n", "arrays are not supported"),
            ("[speech]\nmodel = \"a/b\"\n[speech.child]\n", "dotted table names are unsupported"),
        ] {
            XCTAssertThrowsError(try ConfigFile.parse(text), text) { error in
                XCTAssertTrue(String(describing: error).contains(message), String(describing: error))
            }
        }
    }

    func testInferenceStatusValuesAreTypedAndCodable() throws {
        let status = InferenceStatus(
            speech: ModelStatus(state: .downloading, detail: "Downloading owner/model"),
            cleanup: ModelStatus(state: .off, detail: "Cleanup disabled")
        )
        XCTAssertEqual(status.speech.state.rawValue, "downloading")
        XCTAssertEqual(status.cleanup.state.rawValue, "off")
        XCTAssertEqual(
            try JSONDecoder().decode(ModelState.self, from: JSONEncoder().encode(ModelState.unreachable)), .unreachable)
    }

    private func parse(_ addition: String) throws -> AppConfig {
        var section: String?
        var hasSpeech = false
        var hasSpeechModel = false
        var hasCleanup = false
        for rawLine in addition.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "[speech]" {
                section = "speech"
                hasSpeech = true
            } else if line == "[cleanup]" {
                section = "cleanup"
                hasCleanup = true
            } else if line.hasPrefix("[") {
                section = nil
            } else if section == "speech" && line.hasPrefix("model") && line.contains("=") {
                hasSpeechModel = true
            }
        }

        var text = addition
        if !hasSpeech {
            text = "[speech]\nmodel = \"owner/speech\"\n" + text
        } else if !hasSpeechModel {
            text = text.replacingOccurrences(
                of: "[speech]", with: "[speech]\nmodel = \"owner/speech\"", range: text.range(of: "[speech]"))
        }
        if !hasCleanup { text += "\n[cleanup]\nenabled = false\n" }
        return try ConfigFile.parse(text)
    }
}
