//
//  AgentMonitorManager.swift
//  boringNotch — Agent Monitor
//
//  Singleton that owns the loopback event listener and the live session table.
//  Folds in the standalone app's SessionStore logic, converted from
//  @Observable to the boringNotch house style (ObservableObject + @Published,
//  `.shared` singleton).
//

import Defaults
import Foundation
import SwiftUI
import os

@MainActor
final class AgentMonitorManager: ObservableObject {
  static let shared = AgentMonitorManager()

  private let logger = Logger(subsystem: "com.notchagent.app", category: "manager")

  /// All tracked sessions keyed by stable session ID.
  @Published private(set) var sessions: [String: Session] = [:]

  /// Last attention signal (set when a session enters waiting/done/failed).
  /// The notch UI observes this to fire a brief peek (Phase C).
  @Published private(set) var lastAlert: NotchAlert?
  private var alertSeq = 0

  private var receiver: EventReceiver?
  private var started = false
  private var maintenanceTimer: Timer?

  /// Drop idle (`waiting`/`done`) sessions after this long with no activity —
  /// a safety net for sessions that never send a `session_end`. (The idle and
  /// stall thresholds are user-configurable; see `Defaults.Keys`.)
  private let idleTTL: TimeInterval = 30 * 60

  /// Tools whose `pre_tool` means the agent is blocked awaiting the user, so
  /// the session is "needs input" rather than "working" while they run.
  private static let interactiveTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

  private init() {}

  // MARK: - Derived

  /// Most-urgent status across all sessions; nil when empty.
  var mostUrgentStatus: SessionStatus? {
    sessions.values.map(\.status).max(by: { $0.urgency < $1.urgency })
  }

  /// The session driving the current collapsed indicator (most urgent).
  var mostUrgentSession: Session? {
    sessions.values.max(by: { $0.status.urgency < $1.status.urgency })
  }

  /// True when any session is being tracked — drives Agents-tab visibility (Phase B).
  var hasActiveSessions: Bool { !sessions.isEmpty }

  // MARK: - Lifecycle

  /// Start the loopback listener. Idempotent. No-op when disabled in settings.
  func start() {
    guard Defaults[.agentMonitorEnabled] else { return }
    guard !started else { return }
    started = true
    AgentNotificationManager.shared.configure()
    let configured = Defaults[.agentListenerPort]
    let port: UInt16 = (configured > 0 && configured <= 65535) ? UInt16(configured) : 7878
    let receiver = EventReceiver(port: port, store: self)
    self.receiver = receiver
    Task {
      do {
        try await receiver.start()
      } catch {
        logger.error(
          "EventReceiver failed to start: \(String(describing: error), privacy: .public)")
      }
    }
    startMaintenanceTimer()
  }

  /// Stop the listener and release it.
  func stop() {
    maintenanceTimer?.invalidate()
    maintenanceTimer = nil
    let receiver = self.receiver
    Task { await receiver?.stop() }
    self.receiver = nil
    started = false
  }

  /// Periodic upkeep timer, added to the main run loop (fires on the main actor).
  private func startMaintenanceTimer() {
    maintenanceTimer?.invalidate()
    maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.runMaintenance() }
    }
  }

  /// Drop dead sessions: any session with no activity past the TTL. This is the
  /// safety net for sessions that never send a `session_end` (the bridge does
  /// not wire Claude Code's SessionEnd hook yet). No status guessing — state is
  /// driven entirely by the Notification / Stop hooks. Iterates a snapshot so
  /// the dictionary can be mutated safely.
  private func runMaintenance() {
    let now = Date()
    for (key, s) in Array(sessions) where now.timeIntervalSince(s.lastActivity) > idleTTL {
      sessions.removeValue(forKey: key)
      logger.debug("session pruned (idle > TTL): \(key, privacy: .public)")
    }
  }

  // MARK: - Update (folded from SessionStore)

  /// Apply an incoming event to session state. Called from EventReceiver via Task hop.
  func update(event: Event) {
    let key = sessionKey(for: event)

    switch event.event {
    case .sessionStart:
      sessions[key] = Session(
        id: key,
        source: event.source,
        pid: event.pid,
        cwd: event.cwd,
        status: .working,
        lastTool: nil,
        lastActivity: .init(),
        startedAt: .init()
      )
      logger.debug("session created: \(key, privacy: .public)")

    case .userPrompt:
      // User submitted a prompt → the agent is back to work. Clears a lingering
      // temp-done the instant you type, before the first tool call arrives.
      var s = adoptedSession(key: key, event: event)
      s.status = .working
      s.lastActivity = .init()
      sessions[key] = s

    case .preTool:
      var s = adoptedSession(key: key, event: event)
      var tool: String?
      if case .object(let obj) = event.payload,
        case .string(let t) = obj["tool_name"]
      {
        tool = t
        s.lastTool = t
      }
      s.lastActivity = .init()
      if let tool, Self.interactiveTools.contains(tool) {
        // This tool blocks on the user (e.g. AskUserQuestion, ExitPlanMode):
        // the agent is awaiting *you*, not working. Show "need input".
        let wasNeedInput = s.status == .needInput
        s.status = .needInput
        sessions[key] = s
        if !wasNeedInput { emitAlert(for: s) }
      } else {
        s.status = .working
        sessions[key] = s
      }

    case .postTool:
      var s = adoptedSession(key: key, event: event)
      s.lastActivity = .init()
      s.status = .working  // tool returned (incl. a user answer) → back to work
      sessions[key] = s

    // PermissionRequest hook (Claude Code ≥ 2.0): a permission dialog appeared
    // for a tool. This is the deterministic "needs your approval" signal —
    // focus-independent, no timer guessing. (E1 only observes; Claude Code
    // still shows its own terminal prompt. E2 will let us decide from here.)
    case .permissionRequest:
      var s = adoptedSession(key: key, event: event)
      if case .object(let obj) = event.payload,
        case .string(let t) = obj["tool_name"]
      {
        s.lastTool = t
      }
      let wasNeedInput = s.status == .needInput
      s.status = .needInput
      s.lastActivity = .init()
      sessions[key] = s
      logger.debug("session permission-request: \(key, privacy: .public)")
      if !wasNeedInput { emitAlert(for: s) }

    // Notification hook: a notification fired (e.g. the prompt has been idle
    // ~60s awaiting you). Surface as "need input". (Permission requests go
    // through .permissionRequest above, not here, on Claude Code ≥ 2.0.)
    case .waiting:
      var s = adoptedSession(key: key, event: event)
      let wasNeedInput = s.status == .needInput
      s.status = .needInput
      s.lastActivity = .init()
      sessions[key] = s
      logger.debug("session need-input: \(key, privacy: .public)")
      if !wasNeedInput { emitAlert(for: s) }

    // Stop hook: the agent finished its turn and stopped outputting → "temp-
    // done". A session spans many turns, so keep the row alive — the next
    // `pre_tool` flips it back to .working. (Removal is on `session_end` or the
    // idle-TTL prune, never per-turn.)
    case .stop, .turnComplete:
      var s = adoptedSession(key: key, event: event)
      let wasDone = s.status == .tempDone
      s.status = .tempDone
      s.lastActivity = .init()
      sessions[key] = s
      logger.debug("session temp-done: \(key, privacy: .public)")
      if !wasDone { emitAlert(for: s) }

    case .sessionEnd:
      // Real end of the session (e.g. Claude Code's SessionEnd hook, once the
      // bridge forwards it). Drop the row immediately.
      if sessions.removeValue(forKey: key) != nil {
        logger.debug("session ended: \(key, privacy: .public)")
      }

    case .subagentStop:
      logger.debug("subagent stop (no top-level change): \(key, privacy: .public)")

    case .unknown:
      logger.debug("unknown event type ignored for session: \(key, privacy: .public)")
    }
  }

  // MARK: - Private

  /// Publish a one-shot attention signal for `session` and fire a desktop
  /// notification (gated by settings inside the notification manager).
  private func emitAlert(for session: Session) {
    alertSeq += 1
    lastAlert = NotchAlert(
      sessionId: session.id,
      source: session.source,
      cwdBasename: session.cwdBasename,
      status: session.status,
      seq: alertSeq
    )
    AgentNotificationManager.shared.notify(for: session)
  }

  private func sessionKey(for event: Event) -> String {
    if let sid = event.sessionId, !sid.isEmpty { return sid }
    return "\(event.source.rawValue)-\(event.pid)"
  }

  /// Return the existing session for `key`, or lazily adopt a new one from this
  /// event. Lets sessions that began before the monitor started (or survived an
  /// app restart) reappear on their next hook event, instead of being dropped
  /// until they happen to send another `session_start`.
  private func adoptedSession(key: String, event: Event) -> Session {
    if let existing = sessions[key] { return existing }
    logger.debug(
      "session adopted from \(event.event.rawValue, privacy: .public): \(key, privacy: .public)")
    return Session(
      id: key,
      source: event.source,
      pid: event.pid,
      cwd: event.cwd,
      status: .working,
      lastTool: nil,
      lastActivity: .init(),
      startedAt: .init()
    )
  }
}
