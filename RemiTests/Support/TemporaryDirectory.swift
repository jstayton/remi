import Foundation

/// A new, empty folder for one test, removed when the test's value is released.
final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "RemiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func file(_ name: String) -> URL {
    url.appending(path: name)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
