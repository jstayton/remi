import Foundation

/// A JSON array of items in a file. Loading drops anything invalid, and an unreadable
/// file loads as empty (and is logged), so a corrupt file never blocks the app.
struct JSONFile<Item: Codable>: Sendable {
  let url: URL
  let isValid: @Sendable (Item) -> Bool

  func load() -> [Item] {
    guard let data = try? Data(contentsOf: url) else {
      return []
    }
    do {
      return try JSONDecoder().decode([Item].self, from: data).filter(isValid)
    } catch {
      Log.app.error("Ignoring unreadable \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
      return []
    }
  }

  func save(_ items: [Item]) throws {
    try JSONEncoder().encode(items).write(to: url, options: [.atomic, .completeFileProtection])
  }
}
