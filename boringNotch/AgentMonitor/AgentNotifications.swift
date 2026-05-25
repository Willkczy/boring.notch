//
//  AgentNotifications.swift
//  boringNotch — Agent Monitor
//
//  Desktop notifications when an agent session needs the user (needs-input)
//  or looks stuck (stalled). Local notifications work under the existing
//  sandbox — no entitlement needed (only remote push requires aps-environment).
//

import Defaults
import Foundation
import UserNotifications
import os

@MainActor
final class AgentNotificationManager: NSObject, UNUserNotificationCenterDelegate {
  static let shared = AgentNotificationManager()

  private let logger = Logger(subsystem: "com.notchagent.app", category: "notify")
  private var configured = false

  private override init() { super.init() }

  /// Set the delegate and request authorization. Idempotent; call at launch.
  func configure() {
    guard !configured else { return }
    configured = true
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
      Task { @MainActor in
        if let error {
          self?.logger.error("notif auth error: \(String(describing: error), privacy: .public)")
        } else {
          self?.logger.debug("notif auth granted=\(granted, privacy: .public)")
        }
      }
    }
  }

  /// Post a notification for a session that just entered an attention status.
  /// No-op for non-attention statuses or when the relevant toggle is off.
  func notify(for session: Session) {
    guard Defaults[.agentNotificationsEnabled] else { return }

    let title: String
    switch session.status {
    case .waiting:
      guard Defaults[.agentNotifyNeedsInput] else { return }
      title = "\(session.source.rawValue) needs input"
    case .stalled:
      guard Defaults[.agentNotifyStalled] else { return }
      title = "\(session.source.rawValue) may be stuck"
    case .working, .done, .failed:
      return
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = session.cwdBasename + (session.lastTool.map { " · \($0)" } ?? "")
    if Defaults[.agentNotificationSound] { content.sound = .default }

    // One pending notification per session+status, so repeats replace rather
    // than pile up in Notification Center.
    let id = "agent-\(session.id)-\(String(describing: session.status))"
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { [weak self] error in
      if let error {
        Task { @MainActor in
          self?.logger.error("notif add failed: \(String(describing: error), privacy: .public)")
        }
      }
    }
  }

  // Show banners + sound even when boringNotch is the frontmost app.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .list])
  }
}
