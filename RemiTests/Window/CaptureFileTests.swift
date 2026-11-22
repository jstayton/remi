import Foundation
import Testing

@testable import Remi

struct CaptureFileTests {
  private let directory: TemporaryDirectory
  /// 2026-10-11 15:04:06 in the Mac's time zone, which capture names use, whatever its calendar.
  private let date = Calendar(identifier: .gregorian).date(
    from: DateComponents(timeZone: .current, year: 2026, month: 10, day: 11, hour: 15, minute: 4, second: 6))!

  init() throws {
    directory = try TemporaryDirectory()
  }

  private func newName(_ deviceName: String = "iPhone", pathExtension: String = "png") -> String {
    CaptureFile.newURL(deviceName: deviceName, date: date, pathExtension: pathExtension, in: directory.url)
      .lastPathComponent
  }

  @Test("Names a capture like macOS names screenshots")
  func name() {
    #expect(newName() == "Remi iPhone 2026-10-11 at 15.04.06.png")
    #expect(newName(pathExtension: "mov") == "Remi iPhone 2026-10-11 at 15.04.06.mov")
  }

  @Test("Replaces characters Finder can't show", arguments: [("A/B", "A-B"), ("A:B", "A-B"), ("A/:B", "A--B")])
  func unsafeCharacters(deviceName: String, safeName: String) {
    #expect(newName(deviceName) == "Remi \(safeName) 2026-10-11 at 15.04.06.png")
  }

  @Test("Numbers a capture whose name is taken")
  func taken() throws {
    for _ in 0..<2 {
      let url = CaptureFile.newURL(deviceName: "iPhone", date: date, pathExtension: "png", in: directory.url)
      try Data().write(to: url)
    }
    #expect(newName() == "Remi iPhone 2026-10-11 at 15.04.06 (3).png")
  }

  @Test("Only names with the same extension count as taken")
  func otherExtensionTaken() throws {
    try Data().write(to: directory.file("Remi iPhone 2026-10-11 at 15.04.06.mov"))
    #expect(newName() == "Remi iPhone 2026-10-11 at 15.04.06.png")
  }
}
