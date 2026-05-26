//
//  EventReceiver.swift
//  boringNotch — Agent Monitor
//
//  Loopback-only HTTP server that receives agent event envelopes, logs them,
//  and forwards decoded events to AgentMonitorManager.
//
//  Note: boringNotch's sandbox already grants
//  com.apple.security.network.server, so the NWListener binds as-is — the
//  standalone app had to disable the sandbox; here we do not.
//

import Foundation
import Network
import os

actor EventReceiver {
  /// Sendable, immutable members are usable from the connection callbacks
  /// (which run on `queue`) without hopping back into the actor.
  nonisolated let logger = Logger(subsystem: "com.notchagent.app", category: "ipc")
  nonisolated let queue = DispatchQueue(label: "com.notchagent.app.ipc")
  /// Store reference: @MainActor-isolated; callers must `await` when mutating.
  nonisolated let store: AgentMonitorManager

  private let port: NWEndpoint.Port
  private var listener: NWListener?

  init(port: UInt16 = 7878, store: AgentMonitorManager) {
    self.port = NWEndpoint.Port(rawValue: port) ?? 7878
    self.store = store
  }

  /// Binds the listener to 127.0.0.1 only and starts accepting connections.
  func start() throws {
    let parameters = NWParameters.tcp
    // Bind loopback only — never 0.0.0.0 (protocol MUST).
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
    parameters.allowLocalEndpointReuse = true

    let listener = try NWListener(using: parameters)
    self.listener = listener

    listener.newConnectionHandler = { [logger, queue, store] connection in
      EventReceiver.serve(connection, logger: logger, queue: queue, store: store)
    }
    listener.stateUpdateHandler = { [logger, port] state in
      switch state {
      case .ready:
        logger.debug("EventReceiver listening on 127.0.0.1:\(port.rawValue, privacy: .public)")
      case .failed(let error):
        logger.error("EventReceiver failed: \(String(describing: error), privacy: .public)")
      default:
        break
      }
    }
    listener.start(queue: queue)
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  // MARK: - Connection handling (stateless; runs on `queue`)

  private static func serve(
    _ connection: NWConnection, logger: Logger, queue: DispatchQueue, store: AgentMonitorManager
  ) {
    // Defense in depth: even though we bind loopback-only, refuse any
    // connection whose remote endpoint is not loopback.
    guard isLoopback(connection.endpoint) else {
      logger.error(
        "Rejected non-loopback connection from \(String(describing: connection.endpoint), privacy: .public)"
      )
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    receive(connection, buffer: Data(), logger: logger, store: store)
  }

  private static func receive(
    _ connection: NWConnection, buffer: Data, logger: Logger, store: AgentMonitorManager
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      chunk, _, isComplete, error in
      var buffer = buffer
      if let chunk, !chunk.isEmpty {
        buffer.append(chunk)
      }

      do {
        if let body = try HTTPMessage.parseBody(from: buffer) {
          respond(connection, body: body, logger: logger, store: store)
          return
        }
      } catch {
        logger.error("Malformed HTTP request: \(String(describing: error), privacy: .public)")
        send(HTTPMessage.badRequest, on: connection)
        return
      }

      if isComplete || error != nil {
        connection.cancel()
        return
      }
      // Headers or body still incomplete — keep reading.
      receive(connection, buffer: buffer, logger: logger, store: store)
    }
  }

  private static func respond(
    _ connection: NWConnection, body: Data, logger: Logger, store: AgentMonitorManager
  ) {
    do {
      let event = try JSONDecoder().decode(Event.self, from: body)
      let timestamp = event.ts ?? Int(Date().timeIntervalSince1970)
      // Redact payload (protocol SHOULD): log envelope metadata only.
      logger.debug(
        """
        event received: type=\(event.event.rawValue, privacy: .public) \
        source=\(event.source.rawValue, privacy: .public) \
        pid=\(event.pid, privacy: .public) cwd=\(event.cwd, privacy: .public) \
        ts=\(timestamp, privacy: .public) payload=<redacted>
        """)
      if event.event == .permissionRequest {
        // E2: hold the connection open until the app decides (user Allow/Deny
        // or a timeout). The decision is written back as the HTTP body. The
        // bridge blocks on this response. Default-safe: the manager returns
        // `.deferred` for every non-explicit path, so Claude Code's own
        // terminal prompt still applies.
        let id = UUID().uuidString
        // If the bridge closes the connection before we decide (Claude Code
        // killed/abandoned the hook — e.g. the permission was resolved by
        // another path), resolve as deferred so the notch prompt clears at once
        // instead of lingering until the decision timeout.
        watchForClose(connection) {
          Task { await store.resolvePermission(id: id, decision: .deferred) }
        }
        Task {
          let decision = await store.requestPermissionDecision(event: event, id: id)
          send(HTTPMessage.decision(decision), on: connection)
        }
        return
      }
      send(HTTPMessage.noContent, on: connection)
      // Hop to MainActor to update session state.
      Task { await store.update(event: event) }
    } catch {
      logger.error("Event decode failed: \(String(describing: error), privacy: .public)")
      send(HTTPMessage.badRequest, on: connection)
    }
  }

  /// Fire `onClose` when the peer closes the held connection (or it errors)
  /// while we wait to send a decision. A blocked bridge `curl` sends no more
  /// data, so this receive only completes when the connection goes away — the
  /// signal that the pending permission should be cleaned up. (When we send the
  /// decision and cancel, this also fires, but `resolvePermission` is then a
  /// no-op since the pending is already gone.)
  private static func watchForClose(_ connection: NWConnection, onClose: @escaping () -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
      if isComplete || error != nil { onClose() }
    }
  }

  private static func send(_ data: Data, on connection: NWConnection) {
    connection.send(
      content: data,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    switch host {
    case .ipv4(let address):
      return address.rawValue == Data([127, 0, 0, 1])
    case .ipv6(let address):
      return address.rawValue == Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    case .name(let name, _):
      return name == "localhost"
    @unknown default:
      return false
    }
  }
}
