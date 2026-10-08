import Foundation

/// Streaming keeps bytes flowing during long generations so the request timeout only fires on a truly stalled
/// connection. The transport still collects the whole body; this folds the SSE chunks back into the
/// non-streaming response shape the rest of the client parses.
enum OpenRouterStream {
    static func collapse(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(":")
                || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("data:") else { return data }
        var result: [String: Any] = [:]
        var content = ""
        var finishReason: Any = NSNull()
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
            else { continue }
            for key in ["id", "model", "provider", "usage", "error"] where chunk[key] != nil {
                result[key] = chunk[key]
            }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
            if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String {
                content += piece
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }
        result["choices"] = [["message": ["role": "assistant", "content": content], "finish_reason": finishReason]]
        return (try? JSONSerialization.data(withJSONObject: result)) ?? data
    }
}
