//
//  ChatHistoryManager.swift
//  boringNotch — Agent Monitor (vibe-notch port)
//
//  Drives the chat view's history. In vibe-notch this was fed by SessionStore
//  (hook events + Mixpanel); here it is self-contained — it parses the session's
//  JSONL transcript directly via ConversationParser and assembles the
//  [ChatHistoryItem] using ChatHistoryBuilder (the assembly logic ported from
//  vibe's SessionStore.processFileUpdate). A DispatchSource file watcher reparses
//  on every transcript write so the chat updates live, like vibe.
//
//  Public surface matches what the ported ChatView consumes:
//  history(for:), isLoaded(sessionId:), loadFromFile(sessionId:cwd:), $histories,
//  agentDescriptions.
//

import Combine
import Foundation

@MainActor
final class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()

    @Published private(set) var histories: [String: [ChatHistoryItem]] = [:]
    @Published private(set) var agentDescriptions: [String: [String: String]] = [:]

    /// Sessions whose JSONL we've parsed in this app session.
    private var loadedSessions: Set<String> = []
    /// Last-known cwd per session (subagent file derivation still needs it).
    private var cwds: [String: String] = [:]
    /// Resolved transcript path per session (the hook-provided path, which is
    /// authoritative; the derived cwd+sessionId path is only a fallback).
    private var paths: [String: String] = [:]
    /// Agent source per session — picks the transcript parser (Claude vs Codex).
    private var sources: [String: EventSource] = [:]
    /// Active file watchers keyed by session id.
    private var watchers: [String: TranscriptFileWatcher] = [:]

    private init() {}

    // MARK: - Public API

    func history(for sessionId: String) -> [ChatHistoryItem] {
        histories[sessionId] ?? []
    }

    func isLoaded(sessionId: String) -> Bool {
        loadedSessions.contains(sessionId)
    }

    /// Initial load: parse the transcript, assemble items, then start watching the
    /// file for live updates. Idempotent.
    func loadFromFile(sessionId: String, cwd: String, source: EventSource = .claude) async {
        cwds[sessionId] = cwd
        sources[sessionId] = source
        let path = resolvePath(sessionId: sessionId, cwd: cwd)
        paths[sessionId] = path
        await rebuild(sessionId: sessionId, path: path, cwd: cwd, source: source)
        loadedSessions.insert(sessionId)
        startWatching(sessionId: sessionId, path: path, cwd: cwd, source: source)
    }

    /// Drop a session's history + stop its watcher.
    func clearHistory(for sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
        loadedSessions.remove(sessionId)
        cwds.removeValue(forKey: sessionId)
        paths.removeValue(forKey: sessionId)
        sources.removeValue(forKey: sessionId)
        histories.removeValue(forKey: sessionId)
        agentDescriptions.removeValue(forKey: sessionId)
    }

    // MARK: - Rebuild

    /// Prefer the hook-provided transcript path (authoritative — the running
    /// claude process knows its exact JSONL), falling back to deriving it from
    /// cwd+sessionId. The derived path can be wrong because the notch app's
    /// environment (CLAUDE_CONFIG_DIR, ~/.config vs ~/.claude) differs from the
    /// claude shell's, so the title parse worked off the real path while a
    /// derived-path chat read came up empty.
    private func resolvePath(sessionId: String, cwd: String) -> String {
        if let real = AgentMonitorManager.shared.sessions[sessionId]?.transcriptPath,
           !real.isEmpty {
            return real
        }
        return ConversationParser.transcriptFilePath(sessionId: sessionId, cwd: cwd)
    }

    private func rebuild(sessionId: String, path: String, cwd: String, source: EventSource) async {
        let result = await ChatHistoryBuilder.build(sessionId: sessionId, filePath: path, cwd: cwd, source: source)
        histories[sessionId] = Self.filterOutSubagentTools(result.items)
        agentDescriptions[sessionId] = result.agentDescriptions
    }

    private func startWatching(sessionId: String, path: String, cwd: String, source: EventSource) {
        watchers[sessionId]?.stop()
        let watcher = TranscriptFileWatcher(path: path) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Re-resolve in case the path changed (rare), else reuse.
                let p = self.paths[sessionId] ?? path
                await self.rebuild(sessionId: sessionId, path: p, cwd: cwd, source: source)
            }
        }
        watchers[sessionId] = watcher
        watcher.start()
    }

    /// Hide tools that are nested inside a Task/Agent container (they render
    /// inside the container row, not as top-level items). Ported from vibe.
    private static func filterOutSubagentTools(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var subagentToolIds = Set<String>()
        for item in items {
            if case .toolCall(let tool) = item.type, tool.isSubagentContainer {
                for subagentTool in tool.subagentTools {
                    subagentToolIds.insert(subagentTool.id)
                }
            }
        }
        return items.filter { !subagentToolIds.contains($0.id) }
    }
}

// MARK: - Chat History Builder

/// Assembles [ChatHistoryItem] from a session's JSONL transcript. This is the
/// non-incremental path of vibe's SessionStore.processFileUpdate, collapsed into
/// a pure full-reparse (a single open chat is small enough that re-reading the
/// whole transcript per update is fine, and it avoids porting the entire
/// SessionStore event machine).
enum ChatHistoryBuilder {
    struct Result {
        let items: [ChatHistoryItem]
        let agentDescriptions: [String: String]
    }

    static func build(sessionId: String, filePath: String, cwd: String, source: EventSource = .claude) async -> Result {
        // Codex transcripts use a different schema → dedicated parser. It maps
        // to the same ChatHistoryItem models so the views render unchanged.
        if source == .codex {
            let items = await CodexConversationParser.shared.build(filePath: filePath)
            return Result(items: items, agentDescriptions: [:])
        }

        let parser = ConversationParser.shared

        // Reset incremental state so we always parse the whole file fresh.
        await parser.resetState(for: sessionId)
        let messages = await parser.parseFullConversation(sessionId: sessionId, filePath: filePath)
        let completed = await parser.completedToolIds(for: sessionId)
        let toolResults = await parser.toolResults(for: sessionId)
        let structured = await parser.structuredResults(for: sessionId)

        var items: [ChatHistoryItem] = []
        var tracker = ToolTracker()

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let existingIds = Set(items.map { $0.id })
                if let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completed,
                    toolResults: toolResults,
                    structuredResults: structured,
                    toolTracker: &tracker
                ) {
                    items.append(item)
                }
            }
        }

        items.sort { $0.timestamp < $1.timestamp }

        // Populate subagent tools for Task/Agent containers from their agent files.
        var agentDescriptions: [String: String] = [:]
        for i in 0..<items.count {
            guard case .toolCall(var tool) = items[i].type,
                  tool.isSubagentContainer,
                  let structuredResult = structured[items[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            if let description = tool.input["description"] {
                agentDescriptions[taskResult.agentId] = description
            }

            let infos = await parser.parseSubagentTools(
                sessionId: sessionId,
                agentId: taskResult.agentId,
                cwd: cwd
            )
            guard !infos.isEmpty else { continue }

            tool.subagentTools = infos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }
            items[i] = ChatHistoryItem(
                id: items[i].id,
                type: .toolCall(tool),
                timestamp: items[i].timestamp
            )
        }

        return Result(items: items, agentDescriptions: agentDescriptions)
    }

    /// Convert a single message block into a ChatHistoryItem. Ported verbatim
    /// from vibe's SessionStore.createChatItem.
    private static func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .image(let imageBlock):
            let itemId = "\(message.id)-image-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .image(imageBlock), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let timestampStr else { return nil }
        return isoFormatter.date(from: timestampStr)
    }
}

// MARK: - Transcript File Watcher

/// Watches a JSONL transcript file for writes and fires a debounced callback.
/// DispatchSource-based (`.write`/`.extend`), re-arms across atomic rewrites by
/// reopening when the vnode is deleted/renamed. Mirrors the watcher that was in
/// boringNotch's old AgentConversationView.
final class TranscriptFileWatcher {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "agent.transcript.watch", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in self?.open() }
    }

    func stop() {
        queue.async { [weak self] in self?.close() }
    }

    private func open() {
        close()
        fd = Foundation.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic rewrite — reopen the new inode after a brief beat.
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.open() }
            }
            self.fireDebounced()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { Foundation.close(self.fd); self.fd = -1 }
        }
        source = src
        src.resume()
    }

    private func close() {
        source?.cancel()
        source = nil
        if fd >= 0 { Foundation.close(fd); fd = -1 }
    }

    private func fireDebounced() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    deinit { close() }
}
