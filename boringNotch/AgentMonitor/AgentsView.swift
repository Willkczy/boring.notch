//
//  AgentsView.swift
//  boringNotch — Agent Monitor
//
//  Open-notch "Agents" tab: a scrollable list of live Claude Code / Codex
//  sessions. Each row shows source, working-dir basename, last tool, status
//  and elapsed time. Tapping a row focuses that session's terminal via its
//  parent PID. Ported from the standalone app's ExpandedView, restyled for
//  boring.notch's dark open-notch panel (the notch shape + background are
//  owned by ContentView).
//

import AppKit
import Darwin
import SwiftUI

struct AgentsView: View {
  @ObservedObject var manager = AgentMonitorManager.shared

  private var sortedSessions: [Session] {
    manager.sessions.values.sorted { $0.startedAt < $1.startedAt }
  }

  var body: some View {
    Group {
      if sortedSessions.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "terminal")
            .font(.title2)
          Text("No active agent sessions")
            .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(spacing: 4) {
            ForEach(sortedSessions) { session in
              AgentSessionRow(session: session, prompt: manager.pendingPrompt(for: session.id))
                .contentShape(Rectangle())
                .onTapGesture { focusTerminal(hostPid: session.hostPid, fallbackPid: session.pid) }
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Session row

private struct AgentSessionRow: View {
  let session: Session
  /// Live pending permission for this session (nil when none) — drives the
  /// Allow/Deny bar straight from the manager's source of truth.
  let prompt: AgentMonitorManager.PendingPrompt?
  @State private var elapsed: TimeInterval = 0
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Circle()
          .fill(session.status.color)
          .frame(width: 8, height: 8)

        VStack(alignment: .leading, spacing: 2) {
          // Title = latest user prompt (parsed from the JSONL); falls back to
          // the working-dir name until the transcript is read.
          Text(session.title ?? session.cwdBasename)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .lineLimit(1)
          HStack(spacing: 4) {
            Text(session.source.rawValue)
              .foregroundStyle(.secondary)
            Text(session.cwdBasename)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
            if let tool = session.lastTool {
              Text("· \(tool)")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
          }
          .font(.caption2)
        }

        Spacer()

        Text(session.status.label)
          .font(.caption2)
          .foregroundStyle(session.status.color)
        Text(formatElapsed(elapsed))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      // E2: interactive Allow/Deny while this session is awaiting a permission.
      // Driven by the live prompt, so it clears the instant the decision lands.
      if let prompt {
        decisionBar(prompt)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    .onAppear { elapsed = -session.startedAt.timeIntervalSinceNow }
    .onReceive(timer) { _ in elapsed = -session.startedAt.timeIntervalSinceNow }
  }

  @ViewBuilder
  private func decisionBar(_ prompt: AgentMonitorManager.PendingPrompt) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      // Show exactly what is being authorized (security: no truncation of the
      // decision-relevant input beyond a generous limit).
      Text("Permission: \(prompt.tool ?? "tool")")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.orange)
      if let input = prompt.inputSummary, !input.isEmpty {
        Text(input)
          .font(.caption2.monospaced())
          .foregroundStyle(.white.opacity(0.85))
          .lineLimit(3)
          .textSelection(.enabled)
      }
      HStack(spacing: 6) {
        Button("Allow") {
          AgentMonitorManager.shared.resolvePermission(id: prompt.id, decision: .allow)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.small)

        Button("Deny") {
          AgentMonitorManager.shared.resolvePermission(id: prompt.id, decision: .deny)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
  }

  private func formatElapsed(_ s: TimeInterval) -> String {
    let total = max(0, Int(s))
    if total < 60 { return "\(total)s" }
    return "\(total / 60)m\(total % 60)s"
  }
}

// MARK: - Terminal focus

/// Bring the session's host app forward — the terminal emulator (Terminal /
/// iTerm / Ghostty …) or the desktop Claude app. Prefers the bridge-resolved
/// `hostPid` (a stable GUI-app pid that outlives the hook); falls back to
/// walking one level up from the event pid for older bridges.
private func focusTerminal(hostPid: Int?, fallbackPid: Int) {
  if let hostPid, hostPid > 1,
    let app = NSRunningApplication(processIdentifier: pid_t(hostPid))
  {
    app.activate(options: [.activateAllWindows])
    return
  }
  guard
    let ppid = parentPID(of: pid_t(fallbackPid)),
    let app = NSRunningApplication(processIdentifier: ppid)
  else { return }
  app.activate(options: [.activateAllWindows])
}

private func parentPID(of pid: pid_t) -> pid_t? {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.size
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
  let ppid = info.kp_eproc.e_ppid
  return ppid > 1 ? ppid : nil
}
