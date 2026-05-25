//
//  AgentMonitorManager.swift
//  boringNotch — Agent Monitor
//
//  Singleton that owns the loopback event listener and the live session table.
//  Folds in the standalone app's SessionStore logic, converted from
//  @Observable to the boringNotch house style (ObservableObject + @Published,
//  `.shared` singleton).
//

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

  /// Start the loopback listener. Idempotent.
  func start(port: UInt16 = 7878) {
    guard !started else { return }
    started = true
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
  }

  /// Stop the listener and release it.
  func stop() {
    let receiver = self.receiver
    Task { await receiver?.stop() }
    self.receiver = nil
    started = false
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
      sessions[key] = s

    case .postTool:
      guard var s = sessions[key] else { return }
      s.lastActivity = .init()
      sessions[key] = s

    case .waiting:
      guard var s = sessions[key] else { return }
      let wasWaiting = s.status == .waiting
      s.status = .waiting
      sessions[key] = s
      logger.debug("session waiting: \(key, privacy: .public)")
      if !wasWaiting { emitAlert(for: s) }

    case .stop, .turnComplete:
      guard var s = sessions[key] else { return }
      let wasDone = s.status == .done
      s.status = .done
      sessions[key] = s
      logger.debug("session done: \(key, privacy: .public)")
      if !wasDone { emitAlert(for: s) }
      // Remove after 5 s; skip if status changed (e.g. re-used session id).
      Task {
        try? await Task.sleep(for: .seconds(5))
        if sessions[key]?.status == .done {
          sessions.removeValue(forKey: key)
          logger.debug("session removed: \(key, privacy: .public)")
        }
      }

    case .subagentStop:
      logger.debug("subagent stop (no top-level change): \(key, privacy: .public)")

    case .unknown:
      logger.debug("unknown event type ignored for session: \(key, privacy: .public)")
    }
  }

  // MARK: - Private

  /// Publish a one-shot attention signal for `session`.
  private func emitAlert(for session: Session) {
    alertSeq += 1
    lastAlert = NotchAlert(
      sessionId: session.id,
      source: session.source,
      cwdBasename: session.cwdBasename,
      status: session.status,
      seq: alertSeq
    )
  }

  private func sessionKey(for event: Event) -> String {
    if let sid = event.sessionId, !sid.isEmpty { return sid }
    return "\(event.source.rawValue)-\(event.pid)"
  }
}
