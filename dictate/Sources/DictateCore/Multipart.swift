import Foundation

public enum Multipart {
    public static func body(filename: String, mime: String, payload: Data, boundary: String) -> Data {
        var body = Data()
        let header = """
        --\(boundary)\r
        Content-Disposition: form-data; name="audio_file"; filename="\(filename)"\r
        Content-Type: \(mime)\r
        \r

        """
        body.append(Data(header.utf8))
        body.append(payload)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
