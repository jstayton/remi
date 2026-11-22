import Foundation
import Testing

@testable import Remi

struct ScrcpySessionTests {
  private static let h264CodecID: UInt32 = 0x6832_3634
  private static let configurationFlag: UInt8 = 0x40
  private static let sessionFlag: UInt8 = 0x80

  private let server: LoopbackServer

  init() throws {
    server = try LoopbackServer()
  }

  private static func uint32(_ value: UInt32) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian, Array.init)
  }

  /// scrcpy's stream header: a 64-byte, NUL-padded device name, then the codec ID.
  private static func header(name: String, codecID: UInt32 = h264CodecID) -> [UInt8] {
    let nameBytes = Array(name.utf8)
    return nameBytes + [UInt8](repeating: 0, count: 64 - nameBytes.count) + uint32(codecID)
  }

  /// A 12-byte packet header (flags in the top bits of the 8-byte PTS, then the length) and payload.
  private static func packet(_ payload: [UInt8], flags: UInt8 = 0) -> [UInt8] {
    [flags, 0, 0, 0, 0, 0, 0, 1] + uint32(UInt32(payload.count)) + payload
  }

  /// A rotation's session packet: flags, width and height, with no payload.
  private static let sessionPacket: [UInt8] = [sessionFlag, 0, 0, 0] + uint32(1080) + uint32(2400)

  private func readStreamHeader(_ bytes: [UInt8]) throws -> String {
    try ScrcpySession.readStreamHeader(from: server.connect(sending: bytes), serial: "192.168.1.20:5555")
  }

  private func readPackets(_ bytes: [UInt8]) -> (payloads: [[UInt8]], firstVideoAfter: Int?, error: RemiError?) {
    var payloads: [[UInt8]] = []
    var firstVideoAfter: Int?
    do {
      let socket = try server.connect(sending: bytes)
      try ScrcpySession.readPackets(
        from: socket, receive: { payloads.append(Array($0)) },
        onFirstVideo: {
          #expect(firstVideoAfter == nil)
          firstVideoAfter = payloads.count
        })
    } catch {
      return (payloads, firstVideoAfter, error as? RemiError)
    }
    return (payloads, firstVideoAfter, nil)
  }

  @Test("The stream header gives the device's name")
  func deviceName() throws {
    #expect(try readStreamHeader(Self.header(name: "Pixel 9")) == "Pixel 9")
  }

  @Test("A device with no name goes by its serial")
  func noName() throws {
    #expect(try readStreamHeader(Self.header(name: "")) == "192.168.1.20:5555")
  }

  @Test("A device that can't capture its screen says so", arguments: [UInt32(0), 1])
  func captureFailed(codecID: UInt32) {
    #expect {
      try readStreamHeader(Self.header(name: "Pixel 9", codecID: codecID))
    } throws: { error in
      let error = error as? RemiError
      return error?.code == .scrcpyStreamUnavailable && error?.message.hasPrefix("Pixel 9 couldn't") == true
    }
  }

  @Test("Another codec is a protocol error")
  func otherCodec() {
    #expect {
      try readStreamHeader(Self.header(name: "Pixel 9", codecID: 0x6832_3635))
    } throws: { error in
      (error as? RemiError)?.code == .scrcpyProtocolInvalid
    }
  }

  @Test("A header cut short fails")
  func truncatedHeader() {
    #expect {
      try readStreamHeader(Array(Self.header(name: "Pixel 9").prefix(40)))
    } throws: { error in
      (error as? RemiError)?.code == .socketFailed
    }
  }

  @Test("Passes along every payload, and reports the first video after the configuration")
  func packets() {
    let stream =
      Self.packet([0x67, 0x68], flags: Self.configurationFlag) + Self.sessionPacket + Self.packet([0x65, 1, 2])
      + Self.packet([0x41, 3])
    let result = readPackets(stream)
    #expect(result.payloads == [[0x67, 0x68], [0x65, 1, 2], [0x41, 3]])
    #expect(result.firstVideoAfter == 2)
    #expect(result.error?.code == .socketFailed)
  }

  @Test("Configuration alone isn't video")
  func configurationOnly() {
    let result = readPackets(Self.packet([0x67], flags: Self.configurationFlag))
    #expect(result.payloads == [[0x67]])
    #expect(result.firstVideoAfter == nil)
  }

  @Test("An empty or oversized packet is a protocol error", arguments: [UInt32(0), UInt32(16 * 1024 * 1024 + 1)])
  func invalidSize(size: UInt32) {
    let result = readPackets([0, 0, 0, 0, 0, 0, 0, 1] + Self.uint32(size))
    #expect(result.payloads.isEmpty)
    #expect(result.error?.code == .scrcpyProtocolInvalid)
  }
}
