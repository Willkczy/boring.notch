//
//  CodexConversationParser.swift
//  boringNotch — Agent Monitor (vibe-notch port, G6)
//
//  Parses Codex CLI session transcripts (`~/.codex/sessions/YYYY/MM/DD/
//  rollout-*-<id>.jsonl`) into the SAME ChatHistoryItem / ConversationInfo
//  models the ported vibe views render — so ChatView/ToolResultViews work for
//  Codex unchanged. Codex's schema differs from Claude's:
//
//    {"type":"session_meta","payload":{"id","cwd",...}}
//    {"type":"response_item","payload":{"type":"message","role":"user"|"assistant"|"developer",
//        "content":[{"type":"input_text"|"output_text","text":"..."}]}}
//    {"type":"response_item","payload":{"type":"function_call","name","arguments"(JSON str),
//        "call_id","namespace"(optional "mcp__...")}}
//    {"type":"response_item","payload":{"type":"function_call_output","call_id","output"}}
//    {"type":"response_item","payload":{"type":"reasoning",...}}  // shown as thinking
//    event_msg / turn_context  // lifecycle, skipped
//
//  Off-main (actor), failure-tolerant: any malformed line is skipped, never
//  throws into the UI. Full reparse per call (a single open chat is small).
//

import Foundation

actor CodexConversationParser {
    static let shared = CodexConversationParser()

    private init() {}

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Conversation info (instances-list row)

    /// Summary/first/last for the list row. Codex has no summary line, so
    /// firstUserMessage is the title source.
    func parseInfo(filePath: String) -> ConversationInfo {
        guard let lines = readLines(filePath) else {
            return ConversationInfo(
                summary: nil, lastMessage: nil, lastMessageRole: nil,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var lastUserMessageDate: Date?

        for obj in lines {
            guard obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let ptype = payload["type"] as? String

            switch ptype {
            case "message":
                let role = payload["role"] as? String ?? ""
                guard role == "user" || role == "assistant" else { continue }
                let text = Self.messageText(payload)
                guard !text.isEmpty else { continue }
                if role == "user" {
                    if firstUserMessage == nil {
                        firstUserMessage = Self.truncate(text, 50)
                    }
                    if let ts = obj["timestamp"] as? String {
                        lastUserMessageDate = Self.isoFormatter.date(from: ts)
                    }
                }
                lastMessage = Self.truncate(text, 80)
                lastMessageRole = role

            case "function_call":
                let name = Self.toolDisplayName(payload)
                lastMessage = Self.truncate(Self.toolPreview(payload), 80)
                lastMessageRole = "tool"
                lastToolName = name

            default:
                break
            }
        }

        return ConversationInfo(
            summary: nil,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    // MARK: - Full conversation (chat view)

    /// Build the chat history. Returns items only (Codex subagent nesting isn't
    /// modelled in v1, so agentDescriptions is empty).
    func build(filePath: String) -> [ChatHistoryItem] {
        guard let lines = readLines(filePath) else { return [] }

        var items: [ChatHistoryItem] = []
        var toolIndexByCallId: [String: Int] = [:]

        for (lineIndex, obj) in lines.enumerated() {
            guard obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let ptype = payload["type"] as? String
            let timestamp = (obj["timestamp"] as? String).flatMap { Self.isoFormatter.date(from: $0) } ?? Date()

            switch ptype {
            case "message":
                let role = payload["role"] as? String ?? ""
                guard role == "user" || role == "assistant" else { continue }
                let text = Self.messageText(payload)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let id = "codex-msg-\(lineIndex)"
                items.append(ChatHistoryItem(
                    id: id,
                    type: role == "user" ? .user(text) : .assistant(text),
                    timestamp: timestamp
                ))

            case "function_call":
                guard let callId = payload["call_id"] as? String else { continue }
                let name = Self.toolDisplayName(payload)
                let input = Self.toolInput(payload)
                let item = ChatHistoryItem(
                    id: callId,
                    type: .toolCall(ToolCallItem(
                        name: name,
                        input: input,
                        status: .running,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: timestamp
                )
                toolIndexByCallId[callId] = items.count
                items.append(item)

            case "function_call_output":
                guard let callId = payload["call_id"] as? String,
                      let idx = toolIndexByCallId[callId],
                      idx < items.count,
                      case .toolCall(var tool) = items[idx].type else { continue }
                let output = Self.outputText(payload["output"])
                tool.status = .success
                tool.result = output
                tool.structuredResult = .generic(GenericResult(rawContent: output, rawData: nil))
                items[idx] = ChatHistoryItem(id: items[idx].id, type: .toolCall(tool), timestamp: items[idx].timestamp)

            case "reasoning":
                let text = Self.reasoningText(payload)
                guard !text.isEmpty else { continue }
                items.append(ChatHistoryItem(
                    id: "codex-reasoning-\(lineIndex)",
                    type: .thinking(text),
                    timestamp: timestamp
                ))

            default:
                break
            }
        }

        return items
    }

    // MARK: - Helpers

    private func readLines(_ path: String) -> [[String: Any]]? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            out.append(obj)
        }
        return out
    }

    /// Concatenate a message payload's text blocks (input_text / output_text /
    /// plain text / string content).
    private static func messageText(_ payload: [String: Any]) -> String {
        if let s = payload["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = payload["content"] as? [[String: Any]] else { return "" }
        let parts = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "input_text", "output_text", "text": return block["text"] as? String
            default: return nil
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Display name for a Codex tool call. MCP calls carry a `namespace`
    /// (e.g. "mcp__codex_apps__gmail"); combine it with the name so
    /// MCPToolFormatter can prettify it.
    private static func toolDisplayName(_ payload: [String: Any]) -> String {
        let name = payload["name"] as? String ?? "tool"
        if let ns = payload["namespace"] as? String, ns.hasPrefix("mcp__") {
            let n = name.hasPrefix("_") ? String(name.dropFirst()) : name
            return "\(ns)__\(n)"
        }
        return name
    }

    /// Parse the `arguments` JSON string into a string-valued dict, normalizing
    /// Codex's `cmd` to `command` so the shared tool views show it.
    private static func toolInput(_ payload: [String: Any]) -> [String: String] {
        var input: [String: String] = [:]
        if let argStr = payload["arguments"] as? String,
           let d = argStr.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in dict {
                if let s = v as? String { input[k] = s }
                else if let i = v as? Int { input[k] = String(i) }
                else if let b = v as? Bool { input[k] = b ? "true" : "false" }
                else if let d = v as? Double { input[k] = String(d) }
            }
        }
        if input["command"] == nil, let cmd = input["cmd"] { input["command"] = cmd }
        return input
    }

    private static func toolPreview(_ payload: [String: Any]) -> String {
        let input = toolInput(payload)
        if let c = input["command"] { return c.components(separatedBy: "\n").first ?? c }
        if let f = input["file_path"] ?? input["path"] { return (f as NSString).lastPathComponent }
        return input.values.first ?? (payload["name"] as? String ?? "")
    }

    /// Codex tool output can be a string or a structured object — coerce to text.
    private static func outputText(_ output: Any?) -> String {
        if let s = output as? String { return s }
        if let dict = output as? [String: Any] {
            if let s = dict["output"] as? String { return s }
            if let s = dict["content"] as? String { return s }
        }
        if let output, let d = try? JSONSerialization.data(withJSONObject: output),
           let s = String(data: d, encoding: .utf8) { return s }
        return ""
    }

    private static func reasoningText(_ payload: [String: Any]) -> String {
        if let s = payload["text"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let arr = payload["summary"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let s = payload["summary"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }

    private static func truncate(_ s: String, _ maxLen: Int) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > maxLen ? String(cleaned.prefix(maxLen - 1)) + "…" : cleaned
    }
}
