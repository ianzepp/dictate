import Foundation
import Network
import XCTest
import DictateCore
@testable import DictateInference

final class ExternalCleanupTests: XCTestCase {
    func testLoopbackCleanupPreservesRejectedChunksAndRecoversAfterFailure() async throws {
        let server = try LocalCleanupServer()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-http-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configText = """
        [speech]
        model = "\(directory.path)/missing-speech"
        [cleanup]
        url = "http://127.0.0.1:\(server.port)/v1"
        name = "fixture"
        reasoning_effort = "none"
        """
        let configURL = directory.appendingPathComponent("config.toml")
        try configText.write(to: configURL, atomically: true, encoding: .utf8)
        let engine = InferenceEngine(config: try ConfigFile.parse(configText), configURL: configURL)
        try await withinDeadline {
            await engine.prepare()
        }
        let prepared = await engine.status()
        XCTAssertEqual(prepared.speech.state, .failed)
        XCTAssertEqual(prepared.cleanup.state, .ready)

        let protected = Array(repeating: "we should not merge this branch today", count: 6).joined(separator: " ") + "."
        let mixed = try await withinDeadline {
            try await engine.cleanup(text: protected + " um please run the tests.")
        }
        XCTAssertEqual(mixed.text, protected + " Please run the tests.")
        XCTAssertTrue(mixed.used)

        let original = "keep our original draft today."
        let failed = try await withinDeadline { try await engine.cleanup(text: original) }
        XCTAssertEqual(failed.text, original)
        XCTAssertFalse(failed.used)
        let unavailable = await engine.status()
        XCTAssertEqual(unavailable.cleanup.state, .unreachable)

        let recovered = try await withinDeadline { try await engine.cleanup(text: "um hello there.") }
        XCTAssertEqual(recovered.text, "Hello there.")
        XCTAssertTrue(recovered.used)
        let ready = await engine.status()
        XCTAssertEqual(ready.cleanup.state, .ready)
        let requests = server.requests
        XCTAssertEqual(requests.map(\.path), ["/v1/models"] + Array(repeating: "/v1/chat/completions", count: 4))
        XCTAssertEqual(requests.first?.method, "GET")
        for request in requests.dropFirst() {
            XCTAssertEqual(request.method, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "fixture")
            XCTAssertEqual(body["temperature"] as? Double, 0)
            XCTAssertEqual(body["max_tokens"] as? Int, 1024)
            XCTAssertEqual(body["reasoning_effort"] as? String, "none")
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.last?["role"], "user")
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), configText)
    }
}

private func withinDeadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw URLError(.cancelled) }
        return result
    }
}

/// Listener, connection buffers, and request history are confined to one queue.
private final class LocalCleanupServer {
    struct Request {
        let method: String
        let path: String
        let body: Data
    }

    private let queue = DispatchQueue(label: "dictate.tests.cleanup-http")
    private let listener: NWListener
    private var history: [Request] = []
    private var connections: [UUID: NWConnection] = [:]
    var port: UInt16 { listener.port!.rawValue }
    var requests: [Request] { queue.sync { history } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: started.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: self.queue)
            self.receive(connection, id: id, buffer: Data())
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.connections.removeValue(forKey: id)?.cancel()
            }
        }
        listener.start(queue: queue)
        guard started.wait(timeout: .now() + 3) == .success, listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 65_536 else { self.close(id); return }
            if let request = Self.request(buffer) {
                self.history.append(request)
                self.respond(to: request, connection: connection, id: id)
            } else if complete || error != nil { self.close(id) }
            else { self.receive(connection, id: id, buffer: buffer) }
        }
    }

    private static func request(_ data: Data) -> Request? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3 else { return nil }
        let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        guard length >= 0, length <= 65_536, data.count - separator.upperBound >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]),
                       body: Data(data[separator.upperBound..<separator.upperBound + length]))
    }

    private func respond(to request: Request, connection: NWConnection, id: UUID) {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]]
        let text = messages?.last?["content"] ?? ""
        let failed = text.contains("original draft")
        let content: String
        if text.contains("not merge") { content = "We should merge this branch today." }
        else if text.contains("run the tests") { content = "Please run the tests." }
        else { content = "Hello there." }
        let value: [String: Any]
        if request.method == "GET" { value = ["data": []] }
        else if failed { value = ["error": "intentional fixture failure"] }
        else { value = ["choices": [["message": ["content": content]]]] }
        guard let payload = try? JSONSerialization.data(withJSONObject: value) else { close(id); return }
        let status = failed ? "503 Service Unavailable" : "200 OK"
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }
}
