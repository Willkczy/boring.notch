//
//  CodexSessionWatcher.swift
//  boringNotch — Agent Monitor (G7)
//
//  Codex Desktop (the GUI app) runs the agent locally and writes the same
//  `~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl` transcripts as the CLI,
//  but it does NOT fire `~/.codex/hooks.json` into our bridge. So we discover
//  those sessions by polling the sessions directory.
//
//  Observe-only: these sessions carry no pid/hostPid/tty (no focus, no
//  interactive permission, no tmux-send) and coarse status (working /
//  temp-done) derived from the rollout's task_started / task_complete events.
//  CLI sessions (originator "codex-tui") are skipped here — hooks own those.
//

import Foundation

/// A Codex session discovered from disk (not via a hook).
struct DiscoveredCodexSession: Sendable {
    let id: String
    let cwd: String
    let transcriptPath: String
    let status: SessionStatus
    let lastActivity: Date
}

@MainActor
final class CodexSessionWatcher {
    static let shared = CodexSessionWatcher()

    /// Poll cadence. Codex Desktop has no live event stream; 10s keeps the glance
    /// fresh without hammering disk.
    private let pollInterval: TimeInterval = 10
    /// A rollout counts as "active" while its file was modified within this
    /// window. Past that it drops off the tab (Desktop has no end event).
    /// 5 min keeps the tab focused on what's actually in use — Desktop rewrites
    /// the rollout each turn, so anything older is genuinely idle.
    private let activeWindow: TimeInterval = 5 * 60
    /// A session counts as "working" when its rollout was just written. Past
    /// this it flips to `.tempDone` (turn finished, waiting). Bridges the gap
    /// where Desktop doesn't reliably emit `task_started`/`task_complete`.
    private let workingFreshness: TimeInterval = 60

    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let window = activeWindow
        let fresh = workingFreshness
        Task.detached(priority: .utility) {
            let discovered = Self.scan(activeWindow: window, workingFreshness: fresh)
            await MainActor.run {
                AgentMonitorManager.shared.applyDiscoveredCodexSessions(discovered)
            }
        }
    }

    // MARK: - Scan (off-main, failure-tolerant)

    nonisolated private static var sessionsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
                .appendingPathComponent("sessions")
        }
        return home.appendingPathComponent(".codex/sessions")
    }

    /// Scan today's + yesterday's date dirs for recently-modified rollouts.
    nonisolated static func scan(
        activeWindow: TimeInterval, workingFreshness: TimeInterval
    ) -> [DiscoveredCodexSession] {
        let fm = FileManager.default
        let base = sessionsDir
        let now = Date()
        let cutoff = now.addingTimeInterval(-activeWindow)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        let dayDirs = [now, now.addingTimeInterval(-86_400)].map {
            base.appendingPathComponent(fmt.string(from: $0))
        }

        var out: [DiscoveredCodexSession] = []
        for dir in dayDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
                guard let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mod >= cutoff else { continue }
                if let session = parse(file: file, mtime: mod, now: now, workingFreshness: workingFreshness) {
                    out.append(session)
                }
            }
        }
        return out
    }

    /// Read a rollout's session_meta (id/cwd/originator) and derive coarse status
    /// from its task_started / task_complete events when present, falling back
    /// to write-freshness (Desktop doesn't always emit task lifecycle events).
    /// Skips CLI ("codex-tui") and Desktop scratch sessions with no project cwd.
    nonisolated private static func parse(
        file: URL, mtime: Date, now: Date, workingFreshness: TimeInterval
    ) -> DiscoveredCodexSession? {
        guard let data = FileManager.default.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var id: String?
        var cwd = ""
        var originator = ""
        var lastTaskWasComplete = false
        var sawTask = false
        var sawUserMessage = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }

            switch obj["type"] as? String {
            case "session_meta":
                id = payload["id"] as? String
                cwd = payload["cwd"] as? String ?? ""
                originator = payload["originator"] as? String ?? ""
            case "event_msg":
                switch payload["type"] as? String {
                case "task_started":
                    sawTask = true
                    lastTaskWasComplete = false
                case "task_complete":
                    sawTask = true
                    lastTaskWasComplete = true
                default:
                    break
                }
            case "response_item":
                // A scratch session with only `session_meta` and no user prompt
                // is empty noise — surface only sessions where the user actually
                // typed something.
                if payload["type"] as? String == "message",
                   payload["role"] as? String == "user" {
                    sawUserMessage = true
                }
            default:
                break
            }
        }

        guard let id, !id.isEmpty else { return nil }
        // CLI sessions go through hooks; only surface Desktop / other GUI here.
        if originator == "codex-tui" { return nil }
        // Desktop scratch (no project) — cwd "/" or empty → nothing to focus,
        // nothing meaningful to show. Drop.
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespaces)
        if trimmedCwd.isEmpty || trimmedCwd == "/" { return nil }
        // Empty rollout — opened, nothing typed.
        if !sawUserMessage { return nil }

        // Status:
        //   task_started seen, no matching task_complete → working
        //   task_complete seen → tempDone
        //   no task events (Desktop often) → freshness fallback on mtime
        let status: SessionStatus
        if sawTask {
            status = lastTaskWasComplete ? .tempDone : .working
        } else {
            status = (now.timeIntervalSince(mtime) <= workingFreshness) ? .working : .tempDone
        }

        return DiscoveredCodexSession(
            id: id,
            cwd: cwd,
            transcriptPath: file.path,
            status: status,
            lastActivity: mtime
        )
    }
}
