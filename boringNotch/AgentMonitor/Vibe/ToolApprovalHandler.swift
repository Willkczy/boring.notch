//
//  ToolApprovalHandler.swift
//  boringNotch — Agent Monitor (vibe-notch port)
//
//  Sends keystrokes to a tmux pane via `tmux send-keys`. Ported verbatim from
//  vibe-notch (logger subsystem renamed). Powers the chat input (sendMessage)
//  for sessions running inside tmux (G5).
//

import Foundation
import os.log

/// Handles tool approval and message sending for Claude instances via tmux
actor ToolApprovalHandler {
    static let shared = ToolApprovalHandler()

    nonisolated static let logger = Logger(subsystem: "com.notchagent.app", category: "Approval")

    private init() {}

    /// Approve a tool once (sends '1' + Enter)
    func approveOnce(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "1", pressEnter: true)
    }

    /// Approve a tool always (sends '2' + Enter)
    func approveAlways(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "2", pressEnter: true)
    }

    /// Reject a tool with optional message
    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        guard await sendKeys(to: target, keys: "n", pressEnter: true) else {
            return false
        }

        if let message = message, !message.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            return await sendKeys(to: target, keys: message, pressEnter: true)
        }

        return true
    }

    /// Send a message to a tmux target
    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: message, pressEnter: true)
    }

    // MARK: - Private Methods

    private func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // tmux send-keys needs literal text and Enter as separate arguments.
        // Use -l to send keys literally (prevents interpreting special chars).
        let targetStr = target.targetString
        let textArgs = ["send-keys", "-t", targetStr, "-l", keys]

        do {
            Self.logger.debug("Sending text to \(targetStr, privacy: .public)")
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: textArgs)

            if pressEnter {
                Self.logger.debug("Sending Enter key")
                let enterArgs = ["send-keys", "-t", targetStr, "Enter"]
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: enterArgs)
            }
            return true
        } catch {
            Self.logger.error("Error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
