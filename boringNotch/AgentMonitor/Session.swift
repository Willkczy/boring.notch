//
//  Session.swift
//  boringNotch — Agent Monitor
//
//  A single tracked agent session and its status.
//

import SwiftUI

/// The current lifecycle state of an agent session. Three states, each mapped
/// to a distinct Claude Code hook (no timer heuristics):
///   working   — running (session_start / pre_tool / post_tool)
///   needInput — Notification hook: needs permission or input → orange + notify
///   tempDone  — Stop hook: finished the turn, stopped outputting → orange + notify
enum SessionStatus: Sendable, Equatable {
  case working
  case needInput
  case tempDone

  /// SwiftUI color for the status dot. Both attention states are orange.
  var color: Color {
    switch self {
    case .working: .green
    case .needInput, .tempDone: .orange
    }
  }

  /// Priority used to pick the collapsed-dot color. Highest wins.
  var urgency: Int {
    switch self {
    case .needInput: 2
    case .tempDone: 1
    case .working: 0
    }
  }

  /// Short label shown in the row.
  var label: String {
    switch self {
    case .working: "working"
    case .needInput: "need input"
    case .tempDone: "temp-done"
    }
  }

  /// Whether a transition *into* this status should grab attention (peek + notify).
  var alertsAttention: Bool {
    switch self {
    case .needInput, .tempDone: true
    case .working: false
    }
  }
}

/// The outcome of an interactive permission request (E2). `deferred` means
/// "make no decision" — the bridge emits no stdout and Claude Code falls back
/// to its own terminal permission prompt. This is the default-safe outcome for
/// every non-explicit path (observe-only mode, timeout, app down).
enum PermissionDecision: String, Sendable, Equatable {
  case allow
  case deny
  case deferred
}

/// A one-shot attention signal emitted when a session changes to an
/// attention-worthy status. The UI observes it to trigger a brief peek.
struct NotchAlert: Equatable, Sendable {
  let sessionId: String
  let source: EventSource
  let cwdBasename: String
  let status: SessionStatus
  /// Disambiguates repeated alerts of the same status so `onChange` fires.
  let seq: Int
}

/// A single tracked agent session.
struct Session: Identifiable, Sendable {
  /// Stable key: `session_id` when non-empty, else `"\(source)-\(pid)"`.
  let id: String
  let source: EventSource
  let pid: Int
  var cwd: String
  var status: SessionStatus
  /// Name of the last tool invoked, if any.
  var lastTool: String?
  var lastActivity: Date
  let startedAt: Date

  /// E2 interactive permission: when non-nil, this session is awaiting an
  /// Allow/Deny decision in the notch. Cleared when resolved.
  var pendingPermissionId: String? = nil
  /// Human-readable tool input awaiting approval (e.g. the bash command),
  /// shown next to the Allow/Deny buttons.
  var pendingInputSummary: String? = nil

  /// True while an interactive permission decision is pending.
  var awaitingDecision: Bool { pendingPermissionId != nil }

  /// Last path component of `cwd` for compact display.
  var cwdBasename: String {
    URL(fileURLWithPath: cwd).lastPathComponent
  }
}
