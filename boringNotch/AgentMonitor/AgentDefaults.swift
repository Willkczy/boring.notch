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
  /// A tool in flight but silent for this many seconds is surfaced as "needs
  /// input" (likely blocked on a permission prompt). Best-effort: a genuinely
  /// long-running tool also trips this until it finishes.
  static let agentToolWaitThreshold = Key<Double>("agentToolWaitThreshold", default: 45)

  /// A tool in flight but silent for this many seconds is flagged "stalled"
  /// (likely hung). Should be larger than the tool-wait threshold.
  static let agentStallThreshold = Key<Double>("agentStallThreshold", default: 300)

  /// Show a small status dot in the closed (collapsed) notch when a session is
  /// live and the notch is otherwise idle (no music/OSD).
  static let agentNotchIndicator = Key<Bool>("agentNotchIndicator", default: true)
}
