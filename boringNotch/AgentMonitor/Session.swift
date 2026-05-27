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

  /// SwiftUI color for the status dot, everywhere (Agents tab + collapsed
  /// glance): working green / needInput orange / tempDone blue. Distinct per
  /// state so a glance tells "needs you" from "finished".
  var color: Color {
    switch self {
    case .working: .green
    case .needInput: .orange
    case .tempDone: .blue
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
  /// Stable pid of the GUI app hosting this session (set from the event's
  /// `host_pid`), used to focus the terminal / Claude window on row tap.
  var hostPid: Int? = nil
  /// Path to the session's Claude Code JSONL transcript (from the hook payload's
  /// `transcript_path`). Read directly for the title + conversation view (F).
  var transcriptPath: String? = nil
  /// tmux pane tty (e.g. `/dev/ttys003`) when the session runs inside tmux, from
  /// the hook envelope. Enables chat-input send-keys to the pane (G5). nil/empty
  /// for non-tmux sessions → chat stays read-only.
  var tty: String? = nil
  /// Latest user prompt, parsed from the transcript — shown as the row title.
  var title: String? = nil
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
