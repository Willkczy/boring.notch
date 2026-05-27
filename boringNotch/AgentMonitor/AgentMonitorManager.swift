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

  /// True while the transcript view is open — suppresses the notch's
  /// scroll-up-to-close gesture so scrolling the conversation doesn't minimize
  /// the notch (F3).
  @Published var suppressNotchClose = false

  /// Last attention signal (set when a session enters waiting/done/failed).
  /// The notch UI observes this to fire a brief peek (Phase C).
  @Published private(set) var lastAlert: NotchAlert?
  private var alertSeq = 0

  private var receiver: EventReceiver?
  private var started = false
  private var maintenanceTimer: Timer?

  /// E2: in-flight interactive permission requests awaiting an Allow/Deny, keyed
  /// by a generated id. Each holds the continuation that unblocks the bridge.
  private struct PendingPermission {
    let id: String
    let sessionKey: String
    let continuation: CheckedContinuation<PermissionDecision, Never>
  }
  private var pendingPermissions: [String: PendingPermission] = [:]

  /// UI-facing snapshot of pending interactive permissions (no continuations).
  /// This is the SINGLE SOURCE OF TRUTH for the Allow/Deny bar: an entry exists
  /// iff a decision is genuinely outstanding, so the bar appears and clears
  /// exactly in step with `pendingPermissions` — never a stale copied flag.
  struct PendingPrompt: Identifiable, Sendable, Equatable {
    let id: String
    let sessionKey: String
    let tool: String?
    let inputSummary: String?
  }
  @Published private(set) var pendingPrompts: [PendingPrompt] = []

  /// The pending interactive permission for a session, if any (oldest first).
  func pendingPrompt(for sessionKey: String) -> PendingPrompt? {
    pendingPrompts.first { $0.sessionKey == sessionKey }
  }

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

  /// Number of distinct statuses present across sessions = number of dots the
  /// collapsed glance renders. Used to size the notch chin so none clip.
  var activeStatusGroupCount: Int { Set(sessions.values.map(\.status)).count }

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
        hostPid: event.hostPid,
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
      clearPendingPermissions(for: key)
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
      // Tool finished running → any permission for it is resolved.
      clearPendingPermissions(for: key)
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
      // Turn ended → nothing is awaiting a permission decision anymore.
      clearPendingPermissions(for: key)
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

    // F (sandbox-off): read the session's JSONL for a row title. Keep the path
    // fresh; (re)parse the title on a new prompt or the first time we see it.
    if let tp = Self.transcriptPath(from: event.payload), var s = sessions[key] {
      let needTitle = s.title == nil || event.event == .userPrompt
      s.transcriptPath = tp
      sessions[key] = s
      if needTitle { refreshTitle(for: key, path: tp) }
    }
  }

  /// Parse the latest-prompt title off the main actor, then apply it.
  private func refreshTitle(for key: String, path: String) {
    Task.detached(priority: .utility) { [weak self] in
      guard let title = AgentTranscript.latestPrompt(path: path) else { return }
      await MainActor.run {
        guard let self, var s = self.sessions[key], s.title != title else { return }
        s.title = title
        self.sessions[key] = s
      }
    }
  }

  private static func transcriptPath(from payload: JSONValue) -> String? {
    guard case .object(let obj) = payload, case .string(let p)? = obj["transcript_path"]
    else { return nil }
    return p
  }

  /// Remove a session from the table (user "archive"/dismiss from the UI).
  /// Resolves any pending permission first so a held bridge connection unblocks.
  func endSession(id: String) {
    clearPendingPermissions(for: id)
    if sessions.removeValue(forKey: id) != nil {
      logger.debug("session archived by user: \(id, privacy: .public)")
    }
  }

  // MARK: - Interactive permission (E2)

  /// Decide an incoming `permission_request`. Called by EventReceiver, which
  /// holds the bridge connection open until this returns.
  ///
  /// Returns `.allow`/`.deny` only from an explicit user click in the notch.
  /// Every other path — interactive mode OFF, timeout, no decision — returns
  /// `.deferred`, which makes the bridge emit no stdout so Claude Code's own
  /// terminal permission prompt applies. We NEVER auto-allow.
  func requestPermissionDecision(event: Event, id: String) async -> PermissionDecision {
    let key = sessionKey(for: event)
    let (tool, inputSummary) = Self.permissionDetails(from: event.payload)

    var s = adoptedSession(key: key, event: event)
    if let tool { s.lastTool = tool }
    let wasNeedInput = s.status == .needInput
    s.status = .needInput
    s.lastActivity = .init()

    guard Defaults[.agentInteractivePermissions] else {
      // Observe-only (E1 behaviour): surface "need input", defer the decision.
      sessions[key] = s
      logger.debug("permission (observe-only → defer): \(key, privacy: .public)")
      if !wasNeedInput { emitAlert(for: s) }
      return .deferred
    }

    sessions[key] = s
    emitAlert(for: s)

    pendingPrompts.append(
      PendingPrompt(id: id, sessionKey: key, tool: tool, inputSummary: inputSummary))
    logger.debug(
      "permission pending (interactive): \(key, privacy: .public) tool=\(tool ?? "?", privacy: .public)")

    let timeout = max(1, Defaults[.agentDecisionTimeout])
    return await withCheckedContinuation { (cont: CheckedContinuation<PermissionDecision, Never>) in
      pendingPermissions[id] = PendingPermission(id: id, sessionKey: key, continuation: cont)
      // Safety net: if the user never decides, defer to the terminal prompt.
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        self?.resolvePermission(id: id, decision: .deferred, viaTimeout: true)
      }
    }
  }

  /// Resolve a pending interactive permission (user click, or the timeout
  /// safety net). No-op if already resolved. Removing the prompt from
  /// `pendingPrompts` clears the Allow/Deny bar immediately — independent of any
  /// session-status changes, so it can never linger after a decision.
  func resolvePermission(id: String, decision: PermissionDecision, viaTimeout: Bool = false) {
    guard let pending = pendingPermissions.removeValue(forKey: id) else { return }
    pendingPrompts.removeAll { $0.id == id }
    pending.continuation.resume(returning: decision)
    // Allowed or denied → the agent is unblocked and proceeding; reflect that.
    // Deferred → a terminal prompt is now up, so leave it as "need input".
    if decision != .deferred, var s = sessions[pending.sessionKey] {
      s.status = .working
      s.lastActivity = .init()
      sessions[pending.sessionKey] = s
    }
    logger.debug(
      "permission resolved: \(id, privacy: .public) → \(decision.rawValue, privacy: .public) timeout=\(viaTimeout, privacy: .public)"
    )
  }

  /// Resolve (as deferred) and clear any pending interactive permissions for a
  /// session. Called when a forward-progress event proves the agent is no
  /// longer blocked on a decision — the tool ran (`post_tool`) or the turn
  /// ended (`stop`). Claude Code does not always block tool execution on, or
  /// kill, the PermissionRequest hook, so a prompt it resolved by another path
  /// (or never blocked on) would otherwise linger in the notch until the
  /// timeout. Resolving as `.deferred` also unblocks any still-hanging bridge
  /// connection harmlessly (the tool already ran).
  private func clearPendingPermissions(for sessionKey: String) {
    let ids = pendingPermissions.values.filter { $0.sessionKey == sessionKey }.map(\.id)
    for id in ids { resolvePermission(id: id, decision: .deferred) }
  }

  /// Pull a tool name and a short input summary out of a PermissionRequest
  /// payload for display (best-effort).
  private static func permissionDetails(from payload: JSONValue) -> (tool: String?, input: String?) {
    guard case .object(let obj) = payload else { return (nil, nil) }
    var tool: String?
    if case .string(let t) = obj["tool_name"] { tool = t }
    var input: String?
    if case .object(let inObj) = obj["tool_input"] {
      if case .string(let c) = inObj["command"] { input = c }
      else if case .string(let f) = inObj["file_path"] { input = f }
      else if case .string(let p) = inObj["path"] { input = p }
    }
    return (tool, input)
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
    if var existing = sessions[key] {
      // Keep the host pid fresh — e.g. tmux re-attached to a different terminal,
      // or a bridge upgrade now resolves it. Callers write the result back.
      if let hp = event.hostPid, hp > 1 { existing.hostPid = hp }
      return existing
    }
    logger.debug(
      "session adopted from \(event.event.rawValue, privacy: .public): \(key, privacy: .public)")
    return Session(
      id: key,
      source: event.source,
      pid: event.pid,
      hostPid: event.hostPid,
      cwd: event.cwd,
      status: .working,
      lastTool: nil,
      lastActivity: .init(),
      startedAt: .init()
    )
  }
}
