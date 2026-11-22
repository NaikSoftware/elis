import Foundation

/// Normalized event decoded from a provider CLI's JSON line stream.
public enum AssistantStreamEvent: Sendable, Equatable {
    case text(String)
    case conversation(String)
    case turnEnded(error: String?)
}

/// NDJSON input framing and output event decoding for assistant CLIs.
public enum AssistantStream {
    /// Encodes one user turn as a single-line NDJSON message for `.stream` providers.
    public static func encode(_ p: SessionLauncher, text: String) -> String {
        let payload: [String: Any]
        switch p {
        case .claude:
            payload = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": text]],
                ],
            ]
        case .antigravity:
            payload = [
                "event": "user",
                "message": ["content": text],
            ]
        case .terminal, .codex, .opencode:
            return ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return "" }
        return line
    }

    /// Decodes one stdout line from a provider CLI; non-JSON or unrecognized lines return `[]`.
    public static func decode(_ p: SessionLauncher, line: String) -> [AssistantStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{",
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        else { return [] }

        switch p {
        case .claude: return decodeClaude(obj)
        case .antigravity: return decodeAntigravity(obj)
        case .codex: return decodeCodex(obj)
        case .opencode: return decodeOpenCode(obj)
        case .terminal: return []
        }
    }

    private static func decodeClaude(_ obj: [String: Any]) -> [AssistantStreamEvent] {
        switch obj["type"] as? String {
        case "system":
            guard obj["subtype"] as? String == "init",
                  let id = nonEmpty(obj["session_id"])
            else { return [] }
            return [.conversation(id)]
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { return [] }
            return blocks.compactMap { block in
                guard block["type"] as? String == "text", let text = nonEmpty(block["text"]) else { return nil }
                return .text(text)
            }
        case "result":
            guard (obj["is_error"] as? Bool) == true else { return [.turnEnded(error: nil)] }
            let errors = obj["errors"] as? [String]
            let err = errors?.first(where: { !$0.isEmpty })
                ?? nonEmpty(obj["result"])
                ?? nonEmpty(obj["subtype"])
                ?? "error"
            return [.turnEnded(error: err)]
        default:
            return []
        }
    }

    private static func decodeAntigravity(_ obj: [String: Any]) -> [AssistantStreamEvent] {
        switch obj["event"] as? String {
        case "init":
            guard let id = nonEmpty(obj["conversation_id"]) else { return [] }
            return [.conversation(id)]
        case "result":
            // The whole reply arrives here; step_update text_delta fragments would split it into many entries.
            guard let result = obj["result"] as? [String: Any] else { return [] }
            let reply = (result["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text: [AssistantStreamEvent] = reply.isEmpty ? [] : [.text(reply)]
            let status = result["status"] as? String
            if status == nil || status == "SUCCESS" {
                return text + [.turnEnded(error: nil)]
            }
            return text + [.turnEnded(error: nonEmpty(result["error"]) ?? status ?? "error")]
        default:
            return []
        }
    }

    private static func decodeCodex(_ obj: [String: Any]) -> [AssistantStreamEvent] {
        switch obj["type"] as? String {
        case "thread.started":
            guard let id = nonEmpty(obj["thread_id"]) else { return [] }
            return [.conversation(id)]
        case "item.completed":
            guard let item = obj["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = nonEmpty(item["text"])
            else { return [] }
            return [.text(text)]
        case "turn.completed":
            return [.turnEnded(error: nil)]
        case "turn.failed":
            let err = nonEmpty((obj["error"] as? [String: Any])?["message"])
                ?? nonEmpty(obj["error"])
                ?? "turn failed"
            return [.turnEnded(error: err)]
        default:
            return []
        }
    }

    private static func decodeOpenCode(_ obj: [String: Any]) -> [AssistantStreamEvent] {
        switch obj["type"] as? String {
        case "step_start":
            guard let id = nonEmpty(obj["sessionID"]) else { return [] }
            return [.conversation(id)]
        case "text":
            guard let part = obj["part"] as? [String: Any],
                  let text = nonEmpty(part["text"])
            else { return [] }
            return [.text(text)]
        case "step_finish":
            let reason = (obj["part"] as? [String: Any])?["reason"] as? String
            return reason == "tool-calls" ? [] : [.turnEnded(error: nil)]
        case "error":
            let errObj = obj["error"] as? [String: Any]
            let err = nonEmpty((errObj?["data"] as? [String: Any])?["message"])
                ?? nonEmpty(errObj?["message"])
                ?? nonEmpty(errObj?["name"])
                ?? nonEmpty(obj["error"])
                ?? "error"
            return [.turnEnded(error: err)]
        default:
            return []
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
