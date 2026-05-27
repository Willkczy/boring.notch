//
//  AgentTranscript.swift
//  boringNotch — Agent Monitor
//
//  Reads a Claude Code session JSONL transcript directly from disk (the path
//  comes from the hook payload's `transcript_path`). This needs full file
//  access — the app sandbox is disabled for this feature. Parsing runs off the
//  main actor; every entry point is failure-tolerant (returns nil on any I/O or
//  decode error) so a malformed/rotated transcript never breaks the UI.
//

import Foundation

/// One rendered line of the conversation view.
struct TranscriptMessage: Identifiable, Equatable {
  enum Kind: Equatable { case user, assistant, tool }
  let id: Int
  let kind: Kind
  /// User/assistant prose (markdown), or the tool name for `.tool`.
  let text: String
}

enum AgentTranscript {
  /// The most recent user prompt for the session — used as the row title.
  /// Claude Code writes one `last-prompt` record per user turn; we take the
  /// last one (the current task). Scans from the end so it stops after a few
  /// lines instead of parsing the whole (large) transcript.
  static func latestPrompt(path: String) -> String? {
    guard
      let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .utf8)
    else { return nil }

    for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
      guard
        let lineData = line.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
      else { continue }
      if obj["type"] as? String == "last-prompt",
        let prompt = obj["lastPrompt"] as? String, !prompt.isEmpty
      {
        return prompt
      }
    }
    return nil
  }

  /// Parse the conversation for the detail view: user prompts, assistant text,
  /// and tool calls, in order. Skips thinking / tool_result / system / image
  /// noise. Capped to the last `limit` messages. Off-main, failure-tolerant.
  static func conversation(path: String, limit: Int = 200) -> [TranscriptMessage] {
    guard
      let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .utf8)
    else { return [] }

    var out: [TranscriptMessage] = []
    func add(_ kind: TranscriptMessage.Kind, _ s: String) {
      out.append(TranscriptMessage(id: out.count, kind: kind, text: s))
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard
        let lineData = line.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
      else { continue }
      let message = obj["message"] as? [String: Any]
      switch obj["type"] as? String {
      case "user":
        if let s = userText(message), !s.isEmpty { add(.user, s) }
      case "assistant":
        for block in (message?["content"] as? [[String: Any]]) ?? [] {
          switch block["type"] as? String {
          case "text":
            if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty
            { add(.assistant, t) }
          case "tool_use":
            add(.tool, block["name"] as? String ?? "tool")
          default: break  // skip thinking etc.
          }
        }
      default: break  // skip system / attachment / last-prompt / queue-operation
      }
    }
    return Array(out.suffix(limit))
  }

  /// Real user prose only — a string body, or the text blocks of an array body
  /// (skips tool_result / image entries, which are noise in the conversation).
  private static func userText(_ message: [String: Any]?) -> String? {
    guard let message else { return nil }
    if let s = message["content"] as? String {
      return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let arr = message["content"] as? [[String: Any]] {
      let texts = arr.compactMap {
        $0["type"] as? String == "text" ? $0["text"] as? String : nil
      }
      let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      return joined.isEmpty ? nil : joined
    }
    return nil
  }
}
