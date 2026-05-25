//
//  HTTPMessage.swift
//  boringNotch — Agent Monitor
//
//  NWListener delivers a raw TCP byte stream, not parsed HTTP. This is a
//  deliberately minimal HTTP/1.1 helper: enough to pull the request body out
//  of an incoming POST and build a bodiless response. Kept separate from the
//  receiver so the parser stays unit-testable.
//

import Foundation

enum HTTPParseError: Error, Equatable {
  case invalidRequestLine
  case missingContentLength
  case malformedHeaders
}

enum HTTPMessage {
  private static let headerTerminator = Data("\r\n\r\n".utf8)

  /// Attempts to extract the request body from accumulated connection bytes.
  ///
  /// - Returns: the body once `Content-Length` bytes have arrived, or `nil`
  ///   if the headers or body are not yet complete (caller should read more).
  /// - Throws: `HTTPParseError` when the request line or headers are
  ///   unparseable, or `Content-Length` is absent.
  static func parseBody(from data: Data) throws -> Data? {
    guard let terminator = data.firstRange(of: headerTerminator) else {
      return nil  // headers not fully received yet
    }

    let headerData = data[data.startIndex..<terminator.lowerBound]
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      throw HTTPParseError.malformedHeaders
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw HTTPParseError.invalidRequestLine
    }

    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/") else {
      throw HTTPParseError.invalidRequestLine
    }

    var contentLength: Int?
    for line in lines.dropFirst() {
      let pair = line.split(separator: ":", maxSplits: 1)
      guard pair.count == 2 else { continue }
      if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
        contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces))
      }
    }
    guard let length = contentLength else {
      throw HTTPParseError.missingContentLength
    }

    let bodyStart = terminator.upperBound
    let available = data.distance(from: bodyStart, to: data.endIndex)
    if available < length {
      return nil  // body not fully received yet
    }

    let bodyEnd = data.index(bodyStart, offsetBy: length)
    return Data(data[bodyStart..<bodyEnd])
  }

  /// A bodiless HTTP/1.1 response with the given status and `Connection: close`.
  static func response(status: Int, reason: String) -> Data {
    let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    return Data(head.utf8)
  }

  /// 204 No Content — successful event receipt.
  static let noContent = response(status: 204, reason: "No Content")

  /// 400 Bad Request — malformed JSON or HTTP.
  static let badRequest = response(status: 400, reason: "Bad Request")
}
