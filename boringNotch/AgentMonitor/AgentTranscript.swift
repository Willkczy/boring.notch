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
}
