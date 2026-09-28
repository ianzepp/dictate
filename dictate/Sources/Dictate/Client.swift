import DictateCore
import Foundation

enum TranscribeError: LocalizedError {
    case badURL
    case server(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badURL: return "Speech service URL is invalid"
        case .server(let detail): return detail
        case .empty: return "Nothing to paste"
        }
    }
}

struct PhaseOne {
    var raw: String
    var replaced: String
}

enum SpeechClient {
    static func recognize(baseURL: String, wav: Data, completion: @escaping (Result<PhaseOne, Error>) -> Void) {
        send(baseURL: baseURL, path: "/transcribe/raw", wav: wav) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                guard
                    let raw = json["raw_transcript"] as? String,
                    let replaced = json["replaced_transcript"] as? String
                else {
                    completion(.failure(TranscribeError.server("Speech service returned an unexpected body")))
                    return
                }
                completion(.success(PhaseOne(raw: raw, replaced: replaced)))
            }
        }
    }

    static func cleanup(baseURL: String, text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = endpoint(baseURL, path: "/cleanup") else {
            completion(.failure(TranscribeError.badURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        URLSession.shared.dataTask(with: request) { data, response, error in
            switch decode(data, response, error) {
            case .failure(let failure):
                completion(.failure(failure))
            case .success(let json):
                guard let cleaned = json["cleaned_transcript"] as? String else {
                    completion(.failure(TranscribeError.server("Cleanup service returned an unexpected body")))
                    return
                }
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    completion(.failure(TranscribeError.empty))
                    return
                }
                completion(.success(trimmed))
            }
        }.resume()
    }

    static func transcribe(baseURL: String, wav: Data, completion: @escaping (Result<String, Error>) -> Void) {
        send(baseURL: baseURL, path: "/transcribe", wav: wav) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                guard let cleaned = json["cleaned_transcript"] as? String else {
                    completion(.failure(TranscribeError.server("Speech service returned an unexpected body")))
                    return
                }
                let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    completion(.failure(TranscribeError.empty))
                    return
                }
                completion(.success(text))
            }
        }
    }

    private static func send(
        baseURL: String,
        path: String,
        wav: Data,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let url = endpoint(baseURL, path: path) else {
            completion(.failure(TranscribeError.badURL))
            return
        }
        let boundary = "dictate-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Multipart.body(filename: "dictation.wav", mime: "audio/wav", payload: wav, boundary: boundary)
        URLSession.shared.dataTask(with: request) { data, response, error in
            completion(decode(data, response, error))
        }.resume()
    }

    private static func decode(_ data: Data?, _ response: URLResponse?, _ error: Error?) -> Result<[String: Any], Error> {
        if let error {
            return .failure(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = data ?? Data()
        if status != 200 {
            return .failure(TranscribeError.server(serverMessage(body, status: status)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(TranscribeError.server("Speech service returned an unexpected body"))
        }
        return .success(json)
    }

    private static func endpoint(_ baseURL: String, path: String) -> URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }

    private static func serverMessage(_ body: Data, status: Int) -> String {
        if
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let detail = json["detail"] as? String,
            !detail.isEmpty
        {
            return detail
        }
        return "Speech service returned HTTP \(status)"
    }
}
