//
//  AgentsSettingsView.swift
//  boringNotch — Agent Monitor
//
//  Settings panel for the Agents feature. Lives in the feature folder (which
//  auto-compiles) and is wired into SettingsView's tab list.
//

import Defaults
import SwiftUI

struct AgentsSettings: View {
  @Default(.agentMonitorEnabled) var enabled
  @Default(.agentNotificationsEnabled) var notificationsEnabled
  @Default(.agentIdleThreshold) var idleThreshold
  @Default(.agentStallThreshold) var stallThreshold
  @Default(.agentListenerPort) var port

  var body: some View {
    Form {
      Section {
        Defaults.Toggle(key: .agentMonitorEnabled) {
          Text("Enable agent monitor")
        }
        .onChange(of: enabled) {
          if enabled {
            AgentMonitorManager.shared.start()
          } else {
            AgentMonitorManager.shared.stop()
          }
        }
      } header: {
        Text("General")
      } footer: {
        HelpText("Listens on 127.0.0.1 for Claude Code / Codex hook events.")
      }

      Section {
        Defaults.Toggle(key: .agentNotificationsEnabled) {
          Text("Enable notifications")
        }
        Defaults.Toggle(key: .agentNotifyNeedsInput) {
          Text("Notify when a session needs input")
        }
        .disabled(!notificationsEnabled)
        Defaults.Toggle(key: .agentNotifyStalled) {
          Text("Notify when a session may be stuck")
        }
        .disabled(!notificationsEnabled)
        Defaults.Toggle(key: .agentNotificationSound) {
          Text("Play sound")
        }
        .disabled(!notificationsEnabled)
      } header: {
        Text("Notifications")
      } footer: {
        HelpText(
          "A session becomes \"needs input\" when it finishes a turn or sits idle. "
            + "macOS asks for notification permission on first launch.")
      }

      Section {
        VStack(alignment: .leading) {
          HStack {
            Text("Idle → needs input")
            Spacer()
            Text("\(Int(idleThreshold))s").foregroundStyle(.secondary)
          }
          Slider(value: $idleThreshold, in: 15...300, step: 15)
        }
        VStack(alignment: .leading) {
          HStack {
            Text("Stall threshold")
            Spacer()
            Text("\(Int(stallThreshold))s").foregroundStyle(.secondary)
          }
          Slider(value: $stallThreshold, in: 60...1800, step: 30)
        }
      } header: {
        Text("Timing")
      } footer: {
        HelpText(
          "An idle working session flips to \"needs input\" after the idle time. "
            + "A tool that runs silently longer than the stall time is flagged as possibly stuck.")
      }

      Section {
        TextField("Listener port", value: $port, format: .number.grouping(.never))
      } header: {
        Text("Advanced")
      } footer: {
        HelpText(
          "Port for the local event listener (default 7878). Takes effect on next launch; "
            + "the bridge must POST to the same port.")
      }
    }
    .accentColor(.effectiveAccent)
    .navigationTitle("Agents")
  }
}
