//
//  AgentNotchIndicator.swift
//  boringNotch — Agent Monitor
//
//  Collapsed (closed-notch) status indicator: one coloured dot per status
//  present across live sessions (green working / orange needs-input / red
//  stalled), with a count when a status has more than one session. Rendered as
//  an overlay on the closed notch (under the camera) so it stays visible
//  regardless of music / OSD content.
//

import SwiftUI

struct AgentNotchIndicator: View {
  @ObservedObject var manager = AgentMonitorManager.shared

  /// Stable display order, most-urgent first.
  private static let order: [SessionStatus] = [.waiting, .stalled, .failed, .working, .done]

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
