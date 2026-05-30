//
//  SessionPhase.swift
//  boringNotch — Agent Monitor (vibe-notch port)
//
//  Explicit state machine for Claude session lifecycle. Ported verbatim from
//  vibe-notch. Our adapter (AgentSessionMonitor) maps boringNotch's 3-state
//  SessionStatus onto these phases so the ported vibe views render unchanged.
//

import Foundation

/// Permission context for tools waiting for approval
struct PermissionContext: Sendable {
    let toolUseId: String
    let toolName: String
    let toolInput: [String: AnyCodable]?
    let receivedAt: Date

    /// Format tool input for display
    var formattedInput: String? {
        guard let input = toolInput else { return nil }

        // For Bash, prioritize showing the command
        if toolName == "Bash", let command = input["command"]?.value as? String {
            return Self.cap(command)
        }

        // For Write/Edit, show the file path
        if toolName == "Write" || toolName == "Edit", let path = input["file_path"]?.value as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }

        // For Read, show the file path
        if toolName == "Read", let path = input["file_path"]?.value as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }

        // Default: show first string value found (skip description)
        let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = input[key]?.value as? String {
                return Self.cap(value)
            }
        }

        // Fallback: first non-description string
        for (key, value) in input where key != "description" {
            if let str = value.value as? String {
                return Self.cap(str)
            }
        }

        return nil
    }

    /// 500-char cap for the row preview. Detail view shows the full value.
    private static func cap(_ s: String) -> String {
        s.count > 500 ? String(s.prefix(500)) + "…" : s
    }
}

extension PermissionContext: Equatable {
    nonisolated static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        // Compare by identity fields only (AnyCodable doesn't conform to Equatable)
        lhs.toolUseId == rhs.toolUseId &&
        lhs.toolName == rhs.toolName &&
        lhs.receivedAt == rhs.receivedAt
    }
}

/// Explicit session phases - the state machine
enum SessionPhase: Sendable {
    /// Session is idle, waiting for user input or new activity
    case idle

    /// Claude is actively processing (running tools, generating response)
    case processing

    /// Claude has finished and is waiting for user input
    case waitingForInput

    /// A tool is waiting for user permission approval
    case waitingForApproval(PermissionContext)

    /// Context is being compacted (auto or manual)
    case compacting

    /// Session has ended
    case ended

    /// Whether this phase indicates the session needs user attention
    var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput:
            return true
        default:
            return false
        }
    }

    /// Whether this phase indicates active processing
    var isActive: Bool {
        switch self {
        case .processing, .compacting:
            return true
        default:
            return false
        }
    }

    /// Whether this is a waitingForApproval phase
    var isWaitingForApproval: Bool {
        if case .waitingForApproval = self {
            return true
        }
        return false
    }

    /// Extract tool name if waiting for approval
    var approvalToolName: String? {
        if case .waitingForApproval(let ctx) = self {
            return ctx.toolName
        }
        return nil
    }
}

// MARK: - Equatable

extension SessionPhase: Equatable {
    nonisolated static func == (lhs: SessionPhase, rhs: SessionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.processing, .processing): return true
        case (.waitingForInput, .waitingForInput): return true
        case (.waitingForApproval(let ctx1), .waitingForApproval(let ctx2)):
            return ctx1 == ctx2
        case (.compacting, .compacting): return true
        case (.ended, .ended): return true
        default: return false
        }
    }
}

// MARK: - Debug Description

extension SessionPhase: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .idle:
            return "idle"
        case .processing:
            return "processing"
        case .waitingForInput:
            return "waitingForInput"
        case .waitingForApproval(let ctx):
            return "waitingForApproval(\(ctx.toolName))"
        case .compacting:
            return "compacting"
        case .ended:
            return "ended"
        }
    }
}
