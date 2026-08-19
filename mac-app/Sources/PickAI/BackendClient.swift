import Foundation

enum QueryMode: String {
    case answer
    case explain
}

enum BackendError: LocalizedError {
    case http(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .http(let statusCode):
            return "Backend returned HTTP \(statusCode)."
        case .decoding:
            return "Backend response could not be decoded."
        }
    }
}

struct ChatMessage: Encodable {
    let role: String
    let text: String?
    let imageBase64: String?

    static func user(text: String) -> ChatMessage {
        ChatMessage(role: "user", text: text, imageBase64: nil)
    }

    static func user(imagePNGData: Data) -> ChatMessage {
        ChatMessage(role: "user", text: nil, imageBase64: imagePNGData.base64EncodedString())
    }

    static func assistant(text: String) -> ChatMessage {
        ChatMessage(role: "assistant", text: text, imageBase64: nil)
    }
}

enum BackendClient {
    private struct RequestBody: Encodable {
        let mode: String
        let messages: [ChatMessage]
    }

    private struct ResponseBody: Decodable {
        let result: String
    }

    static func query(messages: [ChatMessage], mode: QueryMode) async throws -> String {
        do {
            return try await attemptQuery(messages: messages, mode: mode)
        } catch is URLError {
            // Transient connection drops (e.g. a flaky VPN tunnel) are common enough on this
            // machine to be worth one silent retry before surfacing an error to the user.
            try await Task.sleep(nanoseconds: 800_000_000)
            return try await attemptQuery(messages: messages, mode: mode)
        }
    }

    private static func attemptQuery(messages: [ChatMessage], mode: QueryMode) async throws -> String {
        var request = URLRequest(url: Config.backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.sharedSecret, forHTTPHeaderField: "X-Pick-Key")
        request.httpBody = try JSONEncoder().encode(RequestBody(mode: mode.rawValue, messages: messages))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.http(statusCode)
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw BackendError.decoding
        }

        return decoded.result
    }
}
