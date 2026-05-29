//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Agents", icon: "terminal.fill", view: .agents)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var agentManager = AgentMonitorManager.shared
    @Namespace var animation

    /// Home + Shelf always. The Claude and Codex tabs are peers: whenever any
    /// agent session is live, BOTH show (each may be empty) so Codex is always
    /// present alongside Claude — not conditionally hidden per-source.
    private var visibleTabs: [TabModel] {
        var t: [TabModel] = [
            TabModel(label: "Home", icon: "house.fill", view: .home),
            TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
        ]
        if agentManager.hasActiveSessions {
            t.append(TabModel(label: "Claude", icon: "terminal.fill", view: .agents))
            t.append(TabModel(label: "Codex", icon: "chevron.left.forwardslash.chevron.right", view: .codex))
        }
        return t
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
