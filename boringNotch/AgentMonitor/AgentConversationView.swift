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

  @StateObject private var watcher = TranscriptWatcher()
  private static let bottomID = "transcript-bottom"

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

      if watcher.loading {
        Spacer()
        ProgressView().controlSize(.small)
        Spacer()
      } else if watcher.messages.isEmpty {
        Spacer()
        Text("No conversation yet")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(watcher.messages) { message in
                messageRow(message)
              }
              Color.clear.frame(height: 1).id(Self.bottomID)
            }
            .padding(10)
          }
          .scrollIndicators(.never)
          .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
          .onChange(of: watcher.messages.count) {
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      watcher.start(path: session.transcriptPath)
      AgentMonitorManager.shared.suppressNotchClose = true
    }
    .onDisappear {
      watcher.stop()
      AgentMonitorManager.shared.suppressNotchClose = false
    }
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

}

/// Watches a session's JSONL and re-parses the conversation when it grows, so
/// the open transcript updates live (F3). Debounced ~250ms; failure-tolerant.
@MainActor
final class TranscriptWatcher: ObservableObject {
  @Published private(set) var messages: [TranscriptMessage] = []
  @Published private(set) var loading = true

  private var path: String?
  private var source: DispatchSourceFileSystemObject?
  private var reloadTask: Task<Void, Never>?

  func start(path: String?) {
    guard let path else {
      loading = false
      return
    }
    self.path = path
    reload()
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .extend], queue: .global())
    src.setEventHandler { [weak self] in
      Task { @MainActor in self?.scheduleReload() }
    }
    src.setCancelHandler { close(fd) }
    source = src
    src.resume()
  }

  func stop() {
    reloadTask?.cancel()
    reloadTask = nil
    source?.cancel()  // cancel handler closes the fd
    source = nil
  }

  private func scheduleReload() {
    reloadTask?.cancel()
    reloadTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      self?.reload()
    }
  }

  private func reload() {
    guard let path else { return }
    Task.detached(priority: .utility) { [weak self] in
      let parsed = AgentTranscript.conversation(path: path)
      await MainActor.run {
        self?.messages = parsed
        self?.loading = false
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
