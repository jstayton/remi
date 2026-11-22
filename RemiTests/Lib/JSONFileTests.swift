import Foundation
import Testing

@testable import Remi

struct JSONFileTests {
  private struct Item: Codable, Equatable {
    let name: String
  }

  private let directory: TemporaryDirectory
  private let file: JSONFile<Item>

  init() throws {
    directory = try TemporaryDirectory()
    file = JSONFile(url: directory.file("items.json"), isValid: { !$0.name.isEmpty })
  }

  @Test("Saved items load back")
  func roundTrip() throws {
    let items = [Item(name: "one"), Item(name: "two")]
    try file.save(items)
    #expect(file.load() == items)
  }

  @Test("A missing file loads as empty")
  func missingFile() {
    #expect(file.load().isEmpty)
  }

  @Test("An unreadable file loads as empty", arguments: ["", "not json", "{\"name\":\"one\"}", "[{\"nope\":1}]"])
  func unreadableFile(_ contents: String) throws {
    try Data(contents.utf8).write(to: file.url)
    #expect(file.load().isEmpty)
  }

  @Test("Invalid items are dropped when loading")
  func invalidItems() throws {
    try Data(#"[{"name":"one"},{"name":""},{"name":"two"}]"#.utf8).write(to: file.url)
    #expect(file.load() == [Item(name: "one"), Item(name: "two")])
  }

  @Test("Saving replaces what was there")
  func saveReplaces() throws {
    try file.save([Item(name: "one")])
    try file.save([Item(name: "two")])
    #expect(file.load() == [Item(name: "two")])
  }

  @Test("Saving to a folder that doesn't exist throws")
  func saveFails() {
    let missing = JSONFile<Item>(url: directory.file("missing/items.json"), isValid: { _ in true })
    #expect(throws: (any Error).self) {
      try missing.save([Item(name: "one")])
    }
  }
}
