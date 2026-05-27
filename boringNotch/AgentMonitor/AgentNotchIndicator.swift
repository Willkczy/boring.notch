//
//  AgentNotchIndicator.swift
//  boringNotch — Agent Monitor
//
//  Collapsed (closed-notch) status glance, styled like vibe-notch: the Claude
//  crab (legs animate while any session is working) plus a single aggregate
//  status indicator on the right —
//    • amber permission pixel-icon when any session needs input
//    • green ready check when any session finished its turn (temp-done)
//    • animated processing spinner when sessions are only working
//  Rendered as a chin element beside the physical notch (see ContentView's
//  AgentLiveActivity / MusicLiveActivity).
//

import SwiftUI

struct AgentNotchIndicator: View {
  @ObservedObject var manager = AgentMonitorManager.shared

  /// Fixed intrinsic width of the glance (crab + gap + indicator). Used by
  /// ContentView to size/balance the notch chin.
  static let glanceWidth: CGFloat = 40

  private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

  private var anyWorking: Bool {
    manager.sessions.values.contains { $0.status == .working }
  }
  private var anyNeedInput: Bool {
    manager.sessions.values.contains { $0.status == .needInput }
  }
  private var anyTempDone: Bool {
    manager.sessions.values.contains { $0.status == .tempDone }
  }

  var body: some View {
    HStack(spacing: 5) {
      ClaudeCrabIcon(size: 14, color: claudeOrange, animateLegs: anyWorking)
      indicator
    }
  }

  /// Highest-urgency aggregate signal: needInput > tempDone > working.
  @ViewBuilder
  private var indicator: some View {
    if anyNeedInput {
      PermissionIndicatorIcon(size: 14, color: TerminalColors.amber)
    } else if anyTempDone {
      ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
    } else if anyWorking {
      ProcessingSpinner()
    }
  }
}
