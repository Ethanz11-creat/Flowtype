import Foundation

/// Shared PCM16 WAV/multipart serialization. Limits apply to the actual wire body.
enum ASRMultipartRequest {
    static func make(url: URL, model: String?, fields: CloudASRFieldCapabilities, samples: [Float],
                     language: String?, context: ASRContext?, credential: String?, timeout: TimeInterval,
                     maxUploadBytes: Int64?) throws -> URLRequest {
        guard samples.allSatisfy(\.isFinite), samples.count <= (Int(UInt32.max) - 36) / 2,
              let wav = samples.withUnsafeBytes({ WAVEncoder.encode(samples: Data($0), sampleRate: 16000) }) else {
            throw CloudASRError.audioEncodingFailed
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let model { field("model", model) }
        if fields.sendResponseFormat { field("response_format", "json") }
        if fields.sendTemperature { field("temperature", "0.0") }
        if fields.sendLanguage, let language { field("language", language) }
        if fields.sendPrompt, let prompt = composeProviderContext(context) { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        if let limit = maxUploadBytes, Int64(body.count) > limit { throw CloudASRError.apiError(statusCode: 413, message: "") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return request
    }
}
