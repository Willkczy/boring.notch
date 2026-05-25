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
  /// Notify when a session enters "needs input".
  static let agentNotifyNeedsInput = Key<Bool>("agentNotifyNeedsInput", default: true)
  /// Notify when a session looks stalled (a tool ran silently past the threshold).
  static let agentNotifyStalled = Key<Bool>("agentNotifyStalled", default: true)
  /// Play a sound with notifications.
  static let agentNotificationSound = Key<Bool>("agentNotificationSound", default: true)

  /// A working session with no tool in flight and no activity for this many
  /// seconds is demoted to "needs input".
  static let agentIdleThreshold = Key<Double>("agentIdleThreshold", default: 60)
  /// A working session with a tool in flight but silent for this many seconds
  /// is flagged "stalled".
  static let agentStallThreshold = Key<Double>("agentStallThreshold", default: 300)
}
