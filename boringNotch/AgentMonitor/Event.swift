//
//  Event.swift
//  boringNotch — Agent Monitor
//
//  The event envelope sent by hook scripts to the local server.
//  Ported from the standalone notch-agent-monitor app (stdlib-only).
//  Wire schema mirrors that app's docs/protocol.md.
//

import Foundation

/// The kind of agent event. Raw values match the protocol (snake_case).
/// Unrecognized strings decode to `.unknown` rather than failing — a valid
/// JSON envelope with an unknown event type is accepted (and logged), not a
/// 400. This also tolerates capitalized hook names the bridge may forward.
enum AgentEventType: String, Codable, Sendable {
  case sessionStart = "session_start"
  case userPrompt = "user_prompt"
  case preTool = "pre_tool"
  case postTool = "post_tool"
  case permissionRequest = "permission_request"
  case waiting
  case stop
  case subagentStop = "subagent_stop"
  case turnComplete = "turn_complete"
  case sessionEnd = "session_end"
  case unknown

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = AgentEventType(rawValue: raw) ?? .unknown
  }
}

/// Which agent produced the event. Unknown strings decode to `.unknown`.
enum EventSource: String, Codable, Sendable {
  case claude
  case codex
  case unknown

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = EventSource(rawValue: raw) ?? .unknown
  }
}

/// A minimal recursive JSON value, used to carry the opaque `payload` object
/// without pulling in a third-party AnyCodable dependency.
enum JSONValue: Codable, Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Unsupported JSON value"))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

/// The event envelope.
///
/// `ts` is set by the sender (the bridge, at hook-fire time) but is optional
/// here: when absent, the server fills it with the receive time. `session_id`
/// is likewise optional. The remaining fields are required — a missing or
/// wrong-typed value fails decoding, which the server answers with HTTP 400.
struct Event: Codable, Sendable {
  let event: AgentEventType
  let source: EventSource
  let sessionId: String?
  let pid: Int
  let cwd: String
  let ts: Int?
  let payload: JSONValue

  enum CodingKeys: String, CodingKey {
    case event
    case source
    case sessionId = "session_id"
    case pid
    case cwd
    case ts
    case payload
  }
}
