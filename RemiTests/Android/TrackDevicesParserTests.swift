import Foundation
import Synchronization
import Testing

@testable import Remi

struct TrackDevicesParserTests {
  /// Collects what the parser reports, in order.
  private final class Reports: Sendable {
    private let reports = Mutex<[[AndroidDevice]]>([])

    var all: [[AndroidDevice]] { reports.withLock { $0 } }

    func append(_ devices: [AndroidDevice]) {
      reports.withLock { $0.append(devices) }
    }
  }

  private static let wirelessLine =
    "adb-1A2B-xyz._adb-tls-connect._tcp device product:husky model:Pixel_8_Pro device:husky transport_id:3"

  /// Frames `body` the way adb does: its length as 4 hex digits, then the bytes.
  private static func message(_ body: String) -> Data {
    Data(String(format: "%04x", body.utf8.count).utf8) + Data(body.utf8)
  }

  private func parse(_ chunks: [Data]) -> [[AndroidDevice]] {
    let reports = Reports()
    let parser = TrackDevicesParser { reports.append($0) }
    chunks.forEach(parser.append)
    return reports.all
  }

  @Test("Reports a wirelessly connected device with its model name")
  func wirelessDevice() {
    let reports = parse([Self.message(Self.wirelessLine + "\n")])
    #expect(
      reports == [[AndroidDevice(serial: "adb-1A2B-xyz._adb-tls-connect._tcp", model: "Pixel 8 Pro")]])
  }

  @Test("Uses the serial as the name when there's no model")
  func noModel() {
    let reports = parse([Self.message("192.168.1.20:5555 device transport_id:4\n")])
    #expect(reports == [[AndroidDevice(serial: "192.168.1.20:5555", model: "192.168.1.20:5555")]])
  }

  @Test(
    "Skips devices that aren't ready or aren't wireless",
    arguments: [
      "192.168.1.20:5555 offline transport_id:4",
      "192.168.1.20:5555 unauthorized transport_id:4",
      "emulator-5554 device product:sdk model:sdk_gphone device:emu transport_id:1",
      "1A2B3C4D device usb:1-1 model:Pixel_8 transport_id:2",
      "192.168.1.20:5555",
    ])
  func skippedDevice(_ line: String) {
    #expect(parse([Self.message(line + "\n")]) == [[]])
  }

  @Test("Reports an empty list when the last device disconnects")
  func emptyMessage() {
    #expect(parse([Self.message("")]) == [[]])
  }

  @Test("Waits for the rest of a message that's split across reads")
  func splitMessage() {
    let first = Self.message("")
    let second = Self.message(Self.wirelessLine + "\n")
    let reports = Reports()
    let parser = TrackDevicesParser { reports.append($0) }
    // The second message splits inside its length, then inside its body.
    parser.append(first + second.prefix(2))
    parser.append(second.dropFirst(2).prefix(10))
    #expect(reports.all == [[]])
    parser.append(second.dropFirst(12))
    #expect(reports.all.count == 2)
    #expect(reports.all.last?.count == 1)
  }

  @Test("Reports only the latest of several messages in one read")
  func severalMessages() {
    let chunk = Self.message(Self.wirelessLine + "\n") + Self.message("")
    #expect(parse([chunk]) == [[]])
  }

  @Test("Ignores a length that isn't hex")
  func invalidLength() {
    #expect(parse([Data("zzzz".utf8)]).isEmpty)
  }
}
