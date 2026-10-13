import Foundation

/// A blocking TCP connection to 127.0.0.1, read from a dedicated thread. close() only shuts it
/// down (unblocking a read); deinit releases the descriptor, so a read never hits a reused one.
final class LoopbackSocket: @unchecked Sendable {
  private let fileDescriptor: Int32
  private let lock = NSLock()
  private var isShutDown = false

  private init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
  }

  static func connect(port: UInt16) throws -> LoopbackSocket {
    let fileDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fileDescriptor >= 0 else {
      throw RemiError(.socketFailed, "Failed to create a socket (errno \(errno))")
    }
    var noSigPipe: Int32 = 1
    setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      let error = errno
      Darwin.close(fileDescriptor)
      throw RemiError(.socketFailed, "Failed to connect to port \(port) (errno \(error))")
    }
    return LoopbackSocket(fileDescriptor: fileDescriptor)
  }

  /// A read that waits longer than this throws instead of blocking forever. 0 means no timeout.
  func setReadTimeout(seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  /// Reads exactly `count` bytes, throwing if the connection closes first.
  func read(count: Int) throws -> [UInt8] {
    try [UInt8](unsafeUninitializedCapacity: count) { buffer, initializedCount in
      var offset = 0
      while offset < count {
        let received = recv(fileDescriptor, buffer.baseAddress! + offset, count - offset, 0)
        if received < 0 && errno == EINTR {
          continue
        }
        if received < 0 && errno == EAGAIN {
          throw RemiError(.socketFailed, "Timed out waiting for data")
        }
        guard received > 0 else {
          throw RemiError(.socketFailed, received == 0 ? "The connection closed" : "Failed to read (errno \(errno))")
        }
        offset += received
      }
      initializedCount = count
    }
  }

  func close() {
    lock.withLock {
      guard !isShutDown else {
        return
      }
      isShutDown = true
      shutdown(fileDescriptor, SHUT_RDWR)
    }
  }

  deinit {
    close()
    Darwin.close(fileDescriptor)
  }
}
