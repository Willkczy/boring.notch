//
//  AgentSessionMonitor.swift
//  boringNotch — Agent Monitor (vibe-notch port)
//
//  Adapter that bridges boringNotch's flat hook-driven session table
//  (`AgentMonitorManager`) to vibe-notch's rich `SessionState` model, so the
//  ported vibe views (ClaudeInstancesView, ChatView, …) render unchanged.
//
//  This stands in for vibe's `ClaudeSessionMonitor`. It exposes the same surface
//  the views need: `instances`, `approvePermission`, `denyPermission`,
//  `archiveSession`. The chat-history side (chatItems) is filled in via
//  ConversationParser as the chat port (G4) lands; for now conversationInfo +
//  phase drive the instances list.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AgentSessionMonitor: ObservableObject {
    static let shared = AgentSessionMonitor()

    /// Vibe-shaped session list the ported views observe.
    @Published private(set) var instances: [SessionState] = []

    private let manager = AgentMonitorManager.shared
    private let parser = ConversationParser.shared
    private var cancellables = Set<AnyCancellable>()

    /// Coalesces rapid manager updates into one rebuild.
    private var rebuildTask: Task<Void, Never>?

    private init() {
        // Rebuild whenever the underlying session table or pending permissions change.
        manager.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        manager.$pendingPrompts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        scheduleRebuild()
    }

    // MARK: - Rebuild

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        // Snapshot the manager state on the main actor.
        let sessions = Array(manager.sessions.values)
        var built: [SessionState] = []
        built.reserveCapacity(sessions.count)

        for session in sessions {
            let prompt = manager.pendingPrompt(for: session.id)

            // Parse conversation info off the actor (cached by mod-date inside).
            var info = ConversationInfo(
                summary: nil, lastMessage: nil, lastMessageRole: nil,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            )
            if let path = session.transcriptPath {
                info = await parser.parseInfo(filePath: path)
            }
            // Fall back to the manager's parsed title when the transcript has no
            // first-user-message yet (keeps the row from showing only the dir).
            if info.summary == nil && info.firstUserMessage == nil, let title = session.title {
                info = ConversationInfo(
                    summary: nil,
                    lastMessage: info.lastMessage,
                    lastMessageRole: info.lastMessageRole,
                    lastToolName: info.lastToolName,
                    firstUserMessage: title,
                    lastUserMessageDate: info.lastUserMessageDate,
                    usage: info.usage
                )
            }

            built.append(
                SessionState(
                    sessionId: session.id,
                    cwd: session.cwd,
                    projectName: session.cwdBasename,
                    pid: session.pid,
                    tty: nil,
                    isInTmux: false,
                    phase: Self.phase(for: session.status, prompt: prompt),
                    conversationInfo: info,
                    lastActivity: session.lastActivity,
                    createdAt: session.startedAt
                )
            )
        }

        if Task.isCancelled { return }
        instances = built
    }

    /// Map boringNotch's 3-state status onto vibe's phase machine.
    /// - working   → processing (cyan spinner)
    /// - needInput + a live permission → waitingForApproval (amber, Allow/Deny)
    /// - needInput (no permission)     → waitingForInput (green "Ready")
    /// - tempDone  → waitingForInput (finished the turn, ready for input)
    private static func phase(
        for status: SessionStatus,
        prompt: AgentMonitorManager.PendingPrompt?
    ) -> SessionPhase {
        switch status {
        case .working:
            return .processing
        case .needInput:
            if let prompt {
                // Reconstruct a PermissionContext the vibe row can render. We
                // stash the input summary under "command" so PermissionContext's
                // formattedInput surfaces it for any tool.
                let toolInput: [String: AnyCodable]? = prompt.inputSummary.map {
                    ["command": AnyCodable($0)]
                }
                return .waitingForApproval(
                    PermissionContext(
                        toolUseId: prompt.id,
                        toolName: prompt.tool ?? "tool",
                        toolInput: toolInput,
                        receivedAt: Date()
                    )
                )
            }
            return .waitingForInput
        case .tempDone:
            return .waitingForInput
        }
    }

    // MARK: - Actions (vibe ClaudeSessionMonitor surface)

    /// Approve the session's pending interactive permission, if any.
    func approvePermission(sessionId: String) {
        guard let prompt = manager.pendingPrompt(for: sessionId) else { return }
        manager.resolvePermission(id: prompt.id, decision: .allow)
    }

    /// Deny the session's pending interactive permission, if any.
    func denyPermission(sessionId: String, reason: String?) {
        guard let prompt = manager.pendingPrompt(for: sessionId) else { return }
        manager.resolvePermission(id: prompt.id, decision: .deny)
    }

    /// Remove a session from the list (vibe's "archive").
    func archiveSession(sessionId: String) {
        manager.endSession(id: sessionId)
    }
}
