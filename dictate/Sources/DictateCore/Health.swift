public enum ModelState: String, Sendable, Codable {
    case loading
    case downloading
    case ready
    case failed
    case off
    case unreachable
}

public struct ModelStatus: Equatable, Sendable {
    public var state: ModelState
    public var detail: String

    public init(state: ModelState, detail: String) {
        self.state = state
        self.detail = detail
    }
}

public struct InferenceStatus: Equatable, Sendable {
    public var speech: ModelStatus
    public var cleanup: ModelStatus

    public init(speech: ModelStatus, cleanup: ModelStatus) {
        self.speech = speech
        self.cleanup = cleanup
    }
}
