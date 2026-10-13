/// A device row in the status menu, from either the iOS or the Android side.
struct MirrorDevice {
  enum Source {
    case airPlay(deviceID: String)
    /// `serial` (adb's, per connection) only exists while connected. `hardwareSerial` is
    /// unknown for a connection Remi didn't make itself.
    case android(serial: String?, hardwareSerial: String?)
  }

  let name: String
  let source: Source
  /// Paired iOS devices and remembered Android phones are listed even when they aren't connected.
  let isConnected: Bool
  let isMirroring: Bool

  var isAndroid: Bool {
    if case .android = source {
      return true
    }
    return false
  }
}
