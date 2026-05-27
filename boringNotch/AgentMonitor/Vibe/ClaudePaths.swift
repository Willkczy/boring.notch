//
//  ClaudePaths.swift
//  boringNotch — Agent Monitor (vibe-notch port)
//
//  Single source of truth for Claude config directory paths. Ported from
//  vibe-notch, with its AppSettings.claudeDirectoryName override branch removed
//  (boringNotch has no equivalent setting; the hook payload's transcript_path is
//  the primary source, this is the fallback path-derivation for the parser).
//

import Foundation

enum ClaudePaths {

    /// Cached resolved directory to avoid filesystem checks on every access
    private static var _cachedDir: URL?

    /// Guards reads/writes to _cachedDir — accessed from the ConversationParser
    /// actor and background watcher queues, so cross-thread access needs sync.
    private static let cacheLock = NSLock()

    /// Root Claude config directory, resolved once and cached.
    ///
    /// Resolution order:
    /// 1. CLAUDE_CONFIG_DIR environment variable (if set and exists)
    /// 2. ~/.config/claude/ (new default since Claude Code v2.1.30+, if projects/ exists)
    /// 3. ~/.claude/ (legacy fallback)
    static var claudeDir: URL {
        cacheLock.lock()
        if let cached = _cachedDir {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let resolved = resolveClaudeDir()

        cacheLock.lock()
        if let existing = _cachedDir {
            cacheLock.unlock()
            return existing
        }
        _cachedDir = resolved
        cacheLock.unlock()
        return resolved
    }

    static var projectsDir: URL {
        claudeDir.appendingPathComponent("projects")
    }

    /// Invalidate the cached directory so the next access re-resolves.
    static func invalidateCache() {
        cacheLock.lock()
        _cachedDir = nil
        cacheLock.unlock()
    }

    private static func resolveClaudeDir() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. CLAUDE_CONFIG_DIR env var takes highest priority
        if let envDir = Foundation.ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            let expanded = (envDir as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        // 2. New default ~/.config/claude/ (if projects/ exists there)
        let newDefault = home.appendingPathComponent(".config/claude")
        if fm.fileExists(atPath: newDefault.appendingPathComponent("projects").path) {
            return newDefault
        }

        // 3. Legacy fallback
        return home.appendingPathComponent(".claude")
    }
}
