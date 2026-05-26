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
        Defaults.Toggle(key: .agentNotchIndicator) {
          Text("Show status dot in the closed notch")
        }
        .disabled(!enabled)
      } header: {
        Text("General")
      } footer: {
        HelpText(
          "Listens on 127.0.0.1 for Claude Code / Codex hook events. The closed-notch "
            + "dot appears when a session is live and the notch is otherwise idle.")
      }

      Section {
        Defaults.Toggle(key: .agentNotificationsEnabled) {
          Text("Enable notifications")
        }
        Defaults.Toggle(key: .agentNotifyNeedsInput) {
          Text("Notify when a session needs input")
        }
        .disabled(!notificationsEnabled)
        Defaults.Toggle(key: .agentNotifyDone) {
          Text("Notify when a session finishes")
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
          "\"Need input\" fires when Claude asks for permission or input; \"finished\" "
            + "fires each time it stops outputting. macOS asks for notification "
            + "permission on first launch.")
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
