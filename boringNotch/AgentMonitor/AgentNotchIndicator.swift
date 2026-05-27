//
//  AgentNotchIndicator.swift
//  boringNotch — Agent Monitor
//
//  Collapsed (closed-notch) status glance: the Claude crab (vibe-notch identity;
//  legs animate while any session is working) followed by an overall task-status
//  overview — one coloured dot per status currently present, with a count when a
//  status has more than one session:
//    green = working   ·   orange = need-input   ·   blue = temp-done
//  Rendered as a chin element beside the physical notch (see ContentView's
//  AgentLiveActivity / MusicLiveActivity).
//

import SwiftUI

struct AgentNotchIndicator: View {
  @ObservedObject var manager = AgentMonitorManager.shared

  private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

  /// Stable display order, most-urgent first.
  private static let order: [SessionStatus] = [.needInput, .tempDone, .working]

  /// Width of the crab glyph block (size 14 → ~17.8pt, plus breathing room).
  private static let crabBlockWidth: CGFloat = 24
  /// Width budget per status dot+count cell.
  private static let perStatusWidth: CGFloat = 22

  /// Intrinsic width of the glance for a given number of present statuses.
  /// ContentView uses this to size/balance the notch chin so nothing clips.
  static func glanceWidth(statusCount: Int) -> CGFloat {
    crabBlockWidth + CGFloat(max(1, statusCount)) * perStatusWidth
  }

  private var anyWorking: Bool {
    manager.sessions.values.contains { $0.status == .working }
  }

  /// (status, count) for each status that has at least one session.
  private var groups: [(status: SessionStatus, count: Int)] {
    Self.order.compactMap { status in
      let count = manager.sessions.values.filter { $0.status == status }.count
      return count > 0 ? (status, count) : nil
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      ClaudeCrabIcon(size: 14, color: claudeOrange, animateLegs: anyWorking)

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
}
