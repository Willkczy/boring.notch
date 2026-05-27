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

/// Block-level markdown renderer (F4): headings, bulleted/numbered lists,
/// dividers, fenced code blocks, and paragraphs. Inline styling (bold, `code`)
/// within each block via AttributedString. No external dependency.
struct MarkdownText: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func blockView(_ block: Block) -> some View {
    switch block {
    case .heading(let level, let t):
      Text(Self.inline(t))
        .font(.system(size: level <= 1 ? 13 : (level == 2 ? 12 : 11), weight: .bold))
        .foregroundStyle(.white)
        .padding(.top, 2)
    case .bullet(let t):
      HStack(alignment: .top, spacing: 6) {
        Text("•").foregroundStyle(.secondary)
        Text(Self.inline(t)).foregroundStyle(.white.opacity(0.9))
      }
      .font(.caption2)
    case .numbered(let n, let t):
      HStack(alignment: .top, spacing: 6) {
        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
        Text(Self.inline(t)).foregroundStyle(.white.opacity(0.9))
      }
      .font(.caption2)
    case .code(let c):
      Text(c)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    case .divider:
      Divider().background(Color.white.opacity(0.15)).padding(.vertical, 2)
    case .paragraph(let t):
      Text(Self.inline(t))
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.9))
        .textSelection(.enabled)
    }
  }

  private enum Block {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case numbered(num: String, text: String)
    case code(String)
    case divider
    case paragraph(String)
  }

  /// Line-based block parser. Accumulates consecutive prose lines into one
  /// paragraph; pulls fenced ``` blocks out verbatim.
  private static func parse(_ text: String) -> [Block] {
    var blocks: [Block] = []
    var para: [String] = []
    func flushPara() {
      let joined = para.joined(separator: " ").trimmingCharacters(in: .whitespaces)
      if !joined.isEmpty { blocks.append(.paragraph(joined)) }
      para.removeAll()
    }

    var lines = text.components(separatedBy: "\n")[...]
    while let raw = lines.first {
      lines = lines.dropFirst()
      let line = String(raw)
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {  // code fence — consume to the closing fence
        flushPara()
        var code: [String] = []
        while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          code.append(String(next))
          lines = lines.dropFirst()
        }
        if lines.first != nil { lines = lines.dropFirst() }  // drop closing fence
        let body = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !body.isEmpty { blocks.append(.code(body)) }
        continue
      }
      if trimmed.isEmpty { flushPara(); continue }
      if trimmed == "---" || trimmed == "***" || trimmed == "___" {
        flushPara()
        blocks.append(.divider)
        continue
      }
      if let h = heading(trimmed) { flushPara(); blocks.append(h); continue }
      if let b = listItem(trimmed) { flushPara(); blocks.append(b); continue }
      para.append(trimmed)
    }
    flushPara()
    return blocks
  }

  private static func heading(_ s: String) -> Block? {
    guard s.hasPrefix("#") else { return nil }
    let hashes = s.prefix { $0 == "#" }
    let rest = s.dropFirst(hashes.count)
    guard rest.first == " " else { return nil }
    return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
  }

  private static func listItem(_ s: String) -> Block? {
    if s.hasPrefix("- ") || s.hasPrefix("* ") {
      return .bullet(text: String(s.dropFirst(2)))
    }
    // Numbered: "1. text"
    if let dot = s.firstIndex(of: "."), s[s.startIndex..<dot].allSatisfy(\.isNumber),
      s.startIndex != dot, s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " "
    {
      return .numbered(
        num: String(s[s.startIndex..<dot]),
        text: String(s[s.index(dot, offsetBy: 2)...]))
    }
    return nil
  }

  private static func inline(_ s: String) -> AttributedString {
    (try? AttributedString(
      markdown: s,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(s)
  }
}
