//
//  AgentNotchIndicator.swift
//  boringNotch — Agent Monitor
//
//  Collapsed (closed-notch) status indicator: one coloured dot per status
//  present across live sessions (green working / orange need-input /
//  blue temp-done), with a count when a status has more than one session.
//  Rendered as a chin element beside the physical notch (see ContentView's
//  AgentLiveActivity / MusicLiveActivity) so it reads at a glance.
//

import SwiftUI

struct AgentNotchIndicator: View {
  @ObservedObject var manager = AgentMonitorManager.shared

  /// Stable display order, most-urgent first.
  private static let order: [SessionStatus] = [.needInput, .tempDone, .working]

  /// (status, count) for each status that has at least one session.
  private var groups: [(status: SessionStatus, count: Int)] {
    Self.order.compactMap { status in
      let count = manager.sessions.values.filter { $0.status == status }.count
      return count > 0 ? (status, count) : nil
    }
  }

  var body: some View {
    HStack(spacing: 5) {
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        HStack(spacing: 2) {
          Circle()
            .fill(group.status.color)
            .frame(width: 6, height: 6)
          if group.count > 1 {
            Text("\(group.count)")
              .font(.system(size: 8, weight: .bold, design: .rounded))
              .foregroundStyle(.white.opacity(0.85))
          }
        }
      }
    }
  }
}
