import Foundation

enum OpenRouterError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case emptyContent(finishReason: String?)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "还没有设置 OpenRouter API Key，请到「设置」中填写。"
        case let .http(status, message):
            switch status {
            case 402: "OpenRouter 余额或 Key 额度不足（402），请充值后重试。"
            case 403: "模型拒绝了请求（403）：\(message)。该模型可能不支持当前地区，请在设置中换一个模型。"
            default: "请求失败（\(status)）：\(message)"
            }
        case let .emptyContent(reason):
            "模型没有返回内容（finish_reason: \(reason ?? "未知")），请重试或换一个模型。"
        case let .invalidJSON(text):
            "模型返回的内容不是有效的 JSON（已自动重试一次），请重试或换一个模型。返回开头：\(text.prefix(80))"
        }
    }
}

struct OpenRouterClient {
    enum Part {
        case text(String)
        case jpeg(Data)
    }

    struct Response {
        let json: [String: Any]
        let raw: String
    }

    let apiKey: String

    static func fromKeychain() throws -> OpenRouterClient {
        guard let key = KeychainStore.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        return OpenRouterClient(apiKey: key)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 240
        return URLSession(configuration: config)
    }()

    /// Sends a chat completion that must return a single JSON object, retrying once if the reply can't be parsed.
    /// `reasoning: false` disables thinking on reasoning models; nil leaves the model default.
    func chatJSON(model: String, system: String, user: [Part], reasoning: Bool? = nil) async throws -> Response {
        let content: [[String: Any]] = user.map { part in
            switch part {
            case let .text(text):
                return ["type": "text", "text": text]
            case let .jpeg(data):
                return ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]]
            }
        }
        let messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": content],
        ]
        var lastError: Error = OpenRouterError.emptyContent(finishReason: nil)
        for _ in 0..<2 {
            do {
                let text = try await complete(model: model, messages: messages, json: true, reasoning: reasoning)
                guard let json = Self.extractJSONObject(from: text) else { throw OpenRouterError.invalidJSON(text) }
                return Response(json: json, raw: text)
            } catch let error as OpenRouterError {
                switch error {
                case .invalidJSON, .emptyContent: lastError = error
                default: throw error
                }
            }
        }
        throw lastError
    }

    /// Free-form reply for multi-turn chat. `messages` are `["role": ..., "content": ...]` dictionaries.
    func chatText(model: String, messages: [[String: Any]]) async throws -> String {
        try await complete(model: model, messages: messages, json: false, reasoning: nil)
    }

    private func complete(model: String, messages: [[String: Any]], json: Bool, reasoning: Bool?) async throws -> String {
        var provider: [String: Any] = [
            // Without this, OpenRouter may route to a slow provider (observed 10x latency spread).
            "sort": "latency",
        ]
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 16000,
        ]
        if json {
            body["response_format"] = ["type": "json_object"]
            // Some providers silently ignore response_format and reply in prose.
            provider["require_parameters"] = true
        }
        body["provider"] = provider
        if reasoning == false {
            body["reasoning"] = ["enabled": false]
        }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("EnergyTracker", forHTTPHeaderField: "X-Title")
        let payload = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await sendRetryingTransientFailures(request, body: payload)
        let status = response.statusCode
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if let error = object?["error"] as? [String: Any] {
            throw OpenRouterError.http(status: (error["code"] as? Int) ?? status, message: (error["message"] as? String) ?? "未知错误")
        }
        guard status == 200, let object else {
            throw OpenRouterError.http(status: status, message: String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }

        let choice = (object["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        guard let text = message?["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterError.emptyContent(finishReason: choice?["finish_reason"] as? String)
        }
        return text
    }

    private func sendRetryingTransientFailures(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let transientCodes: Set<URLError.Code> = [
            .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .secureConnectionFailed, .dnsLookupFailed, .notConnectedToInternet,
        ]
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await BackgroundTransport.shared.send(request, body: body)
                if attempt < 3, response.statusCode == 429 || (500...599).contains(response.statusCode) {
                    try await Task.sleep(for: .seconds(3 * attempt))
                    continue
                }
                return (data, response)
            } catch let error as URLError where attempt < 3 && transientCodes.contains(error.code) {
                try await Task.sleep(for: .seconds(3 * attempt))
            }
        }
    }

    /// Models occasionally wrap JSON in markdown fences or add prose; take the outermost object.
    private static func extractJSONObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let data = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    struct KeyInfo {
        let usage: Double
        let limitRemaining: Double?
    }

    func keyInfo() async throws -> KeyInfo {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let info = object["data"] as? [String: Any] else {
            throw OpenRouterError.http(status: status, message: "API Key 无效")
        }
        return KeyInfo(usage: JSONValue.double(info["usage"]) ?? 0, limitRemaining: JSONValue.double(info["limit_remaining"]))
    }
}

/// Lenient accessors: models sometimes return numbers as strings ("180" or "180g").
enum JSONValue {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            let digits = string.prefix { $0.isNumber || $0 == "." }
            return Double(digits)
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0.rounded()) }
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }
}
