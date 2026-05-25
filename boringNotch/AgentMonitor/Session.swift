//
//  Session.swift
//  boringNotch — Agent Monitor
//
//  A single tracked agent session and its status.
//

import SwiftUI

/// The current lifecycle state of an agent session.
enum SessionStatus: Sendable, Equatable {
  case working
  case waiting
  case stalled
  case done
  case failed

  /// SwiftUI color for the status dot.
  var color: Color {
    switch self {
    case .working: .green
    case .waiting: .orange
    case .stalled, .failed: .red
    case .done: .gray
    }
  }

  /// Priority used to pick the collapsed-dot color. Highest wins.
  var urgency: Int {
    switch self {
    case .waiting: 4
    case .stalled: 3
    case .working: 2
    case .failed: 1
    case .done: 0
    }
  }

  /// Short label shown in the peek row.
  var label: String {
    switch self {
    case .working: "working"
    case .waiting: "needs input"
    case .stalled: "stalled"
    case .done: "done"
    case .failed: "failed"
    }
  }

  /// Whether a transition *into* this status should grab attention (peek).
  var alertsAttention: Bool {
    switch self {
    case .waiting, .done, .failed: true
    case .working, .stalled: false
    }
  }
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

  /// Last path component of `cwd` for compact display.
  var cwdBasename: String {
    URL(fileURLWithPath: cwd).lastPathComponent
  }
}
