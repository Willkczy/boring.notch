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

  /// E2: approve/deny tool permissions directly from the notch. OFF by default —
  /// when off the app only OBSERVES (need-input display) and defers every
  /// permission to Claude Code's normal terminal prompt. Turning this on makes
  /// the notch's Allow button a real authorization control for tool execution.
  static let agentInteractivePermissions = Key<Bool>("agentInteractivePermissions", default: false)
  /// Seconds to wait for an in-notch Allow/Deny before deferring to the terminal
  /// prompt. Must stay below the bridge's curl timeout (125s).
  static let agentDecisionTimeout = Key<Double>("agentDecisionTimeout", default: 120)

  /// Show a small status dot in the closed (collapsed) notch when a session is
  /// live and the notch is otherwise idle (no music/OSD).
  static let agentNotchIndicator = Key<Bool>("agentNotchIndicator", default: true)
}
