import Foundation

/// The speech service's /health report: one state and a sentence for each model.
public struct ServiceHealth: Equatable {
    public struct Part: Equatable {
        public var state: String
        public var detail: String

        public init(state: String, detail: String) {
            self.state = state
            self.detail = detail
        }
    }

    public var speech: Part
    public var cleanup: Part

    public init(speech: Part, cleanup: Part) {
        self.speech = speech
        self.cleanup = cleanup
    }

    public static func parse(_ data: Data) -> ServiceHealth? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let speech = part(json["speech"]),
            let cleanup = part(json["cleanup"])
        else { return nil }
        return ServiceHealth(speech: speech, cleanup: cleanup)
    }

    private static func part(_ value: Any?) -> Part? {
        guard let table = value as? [String: Any], let state = table["state"] as? String else { return nil }
        return Part(state: state, detail: table["detail"] as? String ?? "")
    }
}
