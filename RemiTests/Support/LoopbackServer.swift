import Foundation

@testable import Remi

/// A one-connection TCP server on 127.0.0.1 that sends fixed bytes and hangs up, standing
/// in for a device's end of an adb forward.
final class LoopbackServer {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  let port: UInt16
  private let listener: Int32

  init() throws {
    let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let isListening = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, $0, &length) == 0
      }
    }
    guard isListening else {
      Darwin.close(listener)
      throw Failure(description: "Failed to listen on 127.0.0.1 (errno \(errno))")
    }
    self.listener = listener
    port = UInt16(bigEndian: address.sin_port)
  }

  /// Connects a LoopbackSocket that reads `bytes`, then sees the connection close.
  func connect(sending bytes: [UInt8]) throws -> LoopbackSocket {
    let socket = try LoopbackSocket.connect(port: port)
    let connection = accept(listener, nil, nil)
    guard connection >= 0 else {
      throw Failure(description: "Failed to accept (errno \(errno))")
    }
    defer { Darwin.close(connection) }
    var offset = 0
    while offset < bytes.count {
      let sent = bytes[offset...].withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
      guard sent > 0 else {
        throw Failure(description: "Failed to send (errno \(errno))")
      }
      offset += sent
    }
    return socket
  }

  deinit {
    Darwin.close(listener)
  }
}
