//
//  AgentConversationView.swift
//  boringNotch — Agent Monitor
//
//  Expandable transcript view for one session (F2). Reads the session's JSONL
//  via AgentTranscript and renders the conversation — user prompts, assistant
//  text (markdown + fenced code blocks), and tool calls. Opened from a row's
//  detail button in AgentsView; a back button returns to the list.
//

import SwiftUI

struct AgentConversationView: View {
  let session: Session
  let onBack: () -> Void

  @State private var messages: [TranscriptMessage] = []
  @State private var loading = true

  var body: some View {
    VStack(spacing: 0) {
      // Header with back button + session title.
      HStack(spacing: 8) {
        Button(action: onBack) {
          Image(systemName: "chevron.left")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        Text(session.title ?? session.cwdBasename)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)

      Divider().background(Color.white.opacity(0.1))

      if loading {
        Spacer()
        ProgressView().controlSize(.small)
        Spacer()
      } else if messages.isEmpty {
        Spacer()
        Text("No conversation yet")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(messages) { message in
              messageRow(message)
            }
          }
          .padding(10)
        }
        .scrollIndicators(.never)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear(perform: load)
  }

  @ViewBuilder
  private func messageRow(_ message: TranscriptMessage) -> some View {
    switch message.kind {
    case .user:
      VStack(alignment: .leading, spacing: 2) {
        Text("You").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        MarkdownText(text: message.text)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    case .assistant:
      VStack(alignment: .leading, spacing: 2) {
        Text("Claude").font(.caption2.weight(.semibold)).foregroundStyle(.green)
        MarkdownText(text: message.text)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .tool:
      HStack(spacing: 5) {
        Image(systemName: "wrench.and.screwdriver.fill")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
        Text(message.text)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
      .padding(.leading, 4)
    }
  }

  private func load() {
    guard let path = session.transcriptPath else {
      loading = false
      return
    }
    Task.detached(priority: .userInitiated) {
      let parsed = AgentTranscript.conversation(path: path)
      await MainActor.run {
        messages = parsed
        loading = false
      }
    }
  }
}

/// Minimal markdown: inline styling via AttributedString, with fenced ```code```
/// blocks pulled out and rendered as monospaced boxes (AttributedString does
/// not handle block-level code).
struct MarkdownText: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, seg in
        if seg.isCode {
          Text(seg.content)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .textSelection(.enabled)
        } else {
          Text(Self.inlineMarkdown(seg.content))
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.9))
            .textSelection(.enabled)
        }
      }
    }
  }

  private struct Segment { let content: String; let isCode: Bool }

  /// Split on ``` fences into alternating prose / code segments.
  private static func segments(_ text: String) -> [Segment] {
    let parts = text.components(separatedBy: "```")
    var result: [Segment] = []
    for (i, part) in parts.enumerated() {
      let isCode = i % 2 == 1  // odd indices are inside fences
      var content = part
      if isCode {
        // Drop a leading language hint line (e.g. "swift\n…").
        if let nl = content.firstIndex(of: "\n") {
          let firstLine = content[content.startIndex..<nl]
          if !firstLine.contains(" ") && firstLine.count < 16 {
            content = String(content[content.index(after: nl)...])
          }
        }
      }
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { result.append(Segment(content: trimmed, isCode: isCode)) }
    }
    return result
  }

  private static func inlineMarkdown(_ s: String) -> AttributedString {
    (try? AttributedString(
      markdown: s,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(s)
  }
}
