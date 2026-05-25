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

  /// Demote silent working sessions to "needs input", and drop idle sessions
  /// past the TTL. Iterates a snapshot so the dictionary can be mutated safely.
  private func runMaintenance() {
    let now = Date()
    let idleThreshold = Defaults[.agentIdleThreshold]
    let stallThreshold = Defaults[.agentStallThreshold]
    for (key, s) in Array(sessions) {
      let idle = now.timeIntervalSince(s.lastActivity)
      switch s.status {
      case .working:
        if s.toolInFlight {
          // A tool is running but has been silent past the stall threshold →
          // flag as possibly stuck (no post_tool, no other event).
          if idle > stallThreshold {
            var u = s
            u.status = .stalled
            sessions[key] = u
            logger.debug("session working→stalled: \(key, privacy: .public)")
            emitAlert(for: u)
          }
        } else if idle > idleThreshold {
          // No tool in flight and silent past the threshold → parked at the
          // prompt awaiting the user.
          var u = s
          u.status = .waiting
          sessions[key] = u
          logger.debug("session idle→waiting: \(key, privacy: .public)")
          emitAlert(for: u)
        }
      case .waiting, .done:
        if idle > idleTTL {
          sessions.removeValue(forKey: key)
          logger.debug("session pruned (idle > TTL): \(key, privacy: .public)")
        }
      case .stalled, .failed:
        break
      }
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

    case .preTool:
      guard var s = sessions[key] else { return }
      if case .object(let obj) = event.payload,
        case .string(let tool) = obj["tool_name"]
      {
        s.lastTool = tool
      }
      s.lastActivity = .init()
      s.status = .working
      s.toolInFlight = true
      sessions[key] = s

    case .postTool:
      guard var s = sessions[key] else { return }
      s.lastActivity = .init()
      s.toolInFlight = false
      sessions[key] = s

    // A finished turn (`stop`/`turn_complete`) and an explicit `waiting`
    // notification mean the same thing for a long-lived session: it is now
    // idle, awaiting the user. A session spans many turns, so keep the row
    // alive and surface it as "needs input" — the next `pre_tool` flips it
    // back to .working. (Removal happens on `session_end` or the idle-TTL
    // prune, never per-turn.)
    case .waiting, .stop, .turnComplete:
      guard var s = sessions[key] else { return }
      let wasWaiting = s.status == .waiting
      s.status = .waiting
      s.toolInFlight = false
      s.lastActivity = .init()
      sessions[key] = s
      logger.debug("session waiting: \(key, privacy: .public)")
      if !wasWaiting { emitAlert(for: s) }

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
}
