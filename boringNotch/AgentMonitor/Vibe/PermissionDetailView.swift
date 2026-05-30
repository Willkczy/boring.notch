//
//  PermissionDetailView.swift
//  boringNotch — Agent Monitor (H3)
//
//  Dedicated permission detail card shown when the user taps an "awaiting
//  approval" row. Reuses the notch-grow + suppress-close lifecycle that
//  ChatView uses (driven by AgentsView). The row preview is intentionally
//  small; this view shows the FULL tool_input so the user can decide without
//  switching to the terminal.
//
//  Per-tool layout:
//    Bash       → command body (monospaced, scroll)
//    Edit       → file path + old_string → new_string blocks
//    MultiEdit  → file path + edits[] flattened to old/new pairs
//    Write      → file path + content body
//    Read       → path + offset/limit if present
//    Grep/Glob  → pattern + scope args
//    fallback   → key/value list of every string field
//

import SwiftUI

struct PermissionDetailView: View {
    let session: SessionState
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onBack: () -> Void

    /// Pulled fresh from the session each render so that if a hook updates the
    /// pending context (rare but possible), the view follows.
    private var context: PermissionContext? { session.phase.permissionContext }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))
            content
            Divider().background(Color.white.opacity(0.08))
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("Permission request")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                Text(MCPToolFormatter.formatToolName(context?.toolName ?? session.pendingToolName ?? "tool"))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.projectName)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
        }
        .padding(.bottom, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let ctx = context {
            ScrollView(.vertical, showsIndicators: true) {
                PermissionFieldStack(context: ctx)
                    .padding(.vertical, 8)
            }
        } else {
            // Permission resolved while view was open — show empty state.
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.4))
                Text("No pending request")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(action: onDeny) {
                Text("Deny")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onAllow) {
                Text("Allow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(TerminalColors.amber)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
        .disabled(context == nil)
        .opacity(context == nil ? 0.4 : 1)
    }

}

// MARK: - Reusable per-tool field renderer

/// Renders every meaningful field of a PermissionContext in tool-specific
/// order. Used by both the standalone PermissionDetailView (full card) and
/// the embedded approval block inside ChatView.
struct PermissionFieldStack: View {
    let context: PermissionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch context.toolName {
            case "Bash":
                field(label: "command", value: stringValue("command"), mono: true)
                if let desc = stringValue("description"), !desc.isEmpty {
                    field(label: "description", value: desc, mono: false)
                }
            case "Edit":
                field(label: "file_path", value: stringValue("file_path"), mono: true)
                field(label: "old_string", value: stringValue("old_string"), mono: true)
                field(label: "new_string", value: stringValue("new_string"), mono: true)
            case "MultiEdit":
                field(label: "file_path", value: stringValue("file_path"), mono: true)
                field(label: "edits", value: stringValue("edits"), mono: true)
            case "Write":
                field(label: "file_path", value: stringValue("file_path"), mono: true)
                field(label: "content", value: stringValue("content"), mono: true)
            case "Read":
                field(label: "file_path", value: stringValue("file_path"), mono: true)
                if let off = stringValue("offset") { field(label: "offset", value: off, mono: false) }
                if let lim = stringValue("limit") { field(label: "limit", value: lim, mono: false) }
            case "Grep":
                field(label: "pattern", value: stringValue("pattern"), mono: true)
                if let p = stringValue("path") { field(label: "path", value: p, mono: true) }
                if let g = stringValue("glob") { field(label: "glob", value: g, mono: true) }
            case "Glob":
                field(label: "pattern", value: stringValue("pattern"), mono: true)
                if let p = stringValue("path") { field(label: "path", value: p, mono: true) }
            default:
                ForEach(allKeys, id: \.self) { key in
                    field(label: key, value: stringValue(key), mono: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func field(label: String, value: String?, mono: Bool) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 11, design: mono ? .monospaced : .default))
                    .foregroundColor(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                    )
            }
        }
    }

    private func stringValue(_ key: String) -> String? {
        guard let any = context.toolInput?[key] else { return nil }
        if let s = any.value as? String { return s }
        if let n = any.value as? Double { return String(n) }
        if let i = any.value as? Int { return String(i) }
        if let b = any.value as? Bool { return b ? "true" : "false" }
        return nil
    }

    private var allKeys: [String] {
        (context.toolInput ?? [:]).keys.sorted()
    }
}
