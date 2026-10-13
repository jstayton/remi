import Foundation

struct RemiError: LocalizedError {
  enum Code: String, Sendable {
    case adbCommandFailed
    case adbNotBundled
    case adbTimedOut
    case airPlayStartFailed
    case androidPairingInputInvalid
    case clientStoreSaveFailed
    case moveToApplicationsFailed
    case recordingFailed
    case scrcpyConnectFailed
    case scrcpyProtocolInvalid
    case scrcpyServerNotBundled
    case scrcpyStreamUnavailable
    case screenshotFailed
    case socketFailed
    case videoFormatInvalid
  }

  let code: Code
  let message: String
  let cause: (any Error & Sendable)?

  init(_ code: Code, _ message: String, cause: (any Error & Sendable)? = nil) {
    self.code = code
    self.message = message
    self.cause = cause
  }

  var errorDescription: String? { message }
}

extension RemiError: CustomStringConvertible {
  var description: String {
    guard let cause else {
      return "[\(code.rawValue)] \(message)"
    }
    return "[\(code.rawValue)] \(message) (cause: \(cause))"
  }
}
