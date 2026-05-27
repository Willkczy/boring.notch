//
//  AgentsView.swift
//  boringNotch — Agent Monitor
//
//  Open-notch "Agents" tab. The session list is the vibe-notch port
//  (`ClaudeInstancesView`, driven by `AgentSessionMonitor`); tapping a row's
//  chat icon opens its transcript (`AgentConversationView`), and the focus/
//  terminal action brings the session's host app forward via its host PID.
//  The notch shape + background are owned by ContentView.
//

import AppKit
import Darwin
import SwiftUI

struct AgentsView: View {
  @ObservedObject var manager = AgentMonitorManager.shared
  @ObservedObject var sessionMonitor = AgentSessionMonitor.shared
  /// Called when the transcript opens (true) / closes (false) so the notch can
  /// grow/restore its window (F4b).
  var onExpandChange: (Bool) -> Void = { _ in }
  /// When set (and the session still exists), show its transcript instead of
  /// the list (F2).
  @State private var expandedSessionId: String?

  var body: some View {
    Group {
      if let id = expandedSessionId, let session = manager.sessions[id] {
        AgentConversationView(session: session, onBack: { expandedSessionId = nil })
      } else {
        ClaudeInstancesView(
          sessionMonitor: sessionMonitor,
          onOpenChat: { expandedSessionId = $0.sessionId },
          onFocus: { focusSession($0) },
          canFocus: { canFocus($0) }
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { onExpandChange(expandedSessionId != nil) }
    .onChange(of: expandedSessionId) { onExpandChange(expandedSessionId != nil) }
    .onDisappear { onExpandChange(false) }
  }

  /// Resolve the live host/event pid for a vibe SessionState and bring it forward.
  private func focusSession(_ session: SessionState) {
    let live = manager.sessions[session.sessionId]
    focusTerminal(hostPid: live?.hostPid, fallbackPid: live?.pid ?? session.pid ?? 0)
  }

  /// Whether we have a focusable pid for this session.
  private func canFocus(_ session: SessionState) -> Bool {
    let live = manager.sessions[session.sessionId]
    if let hp = live?.hostPid, hp > 1 { return true }
    return (live?.pid ?? session.pid ?? 0) > 1
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
    fallbackPid > 1,
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
