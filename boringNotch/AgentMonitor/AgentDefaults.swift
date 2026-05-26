//
//  AgentDefaults.swift
//  boringNotch — Agent Monitor
//
//  Defaults keys for the agent monitor + notifications (Phase D). Kept in the
//  feature folder so the whole feature stays self-contained.
//

import Defaults
import Foundation

extension Defaults.Keys {
  /// Master switch for the whole feature (the loopback listener).
  static let agentMonitorEnabled = Key<Bool>("agentMonitorEnabled", default: true)
  /// Port the local event listener binds (loopback only). Next-launch effect.
  static let agentListenerPort = Key<Int>("agentListenerPort", default: 7878)

  /// Master switch for desktop notifications.
  static let agentNotificationsEnabled = Key<Bool>("agentNotificationsEnabled", default: true)
  /// Notify when a session enters "need input" (Notification hook).
  static let agentNotifyNeedsInput = Key<Bool>("agentNotifyNeedsInput", default: true)
  /// Notify when a session finishes its turn — "temp-done" (Stop hook).
  static let agentNotifyDone = Key<Bool>("agentNotifyDone", default: true)
  /// Play a sound with notifications.
  static let agentNotificationSound = Key<Bool>("agentNotificationSound", default: true)

  /// Show a small status dot in the closed (collapsed) notch when a session is
  /// live and the notch is otherwise idle (no music/OSD).
  static let agentNotchIndicator = Key<Bool>("agentNotchIndicator", default: true)
}
