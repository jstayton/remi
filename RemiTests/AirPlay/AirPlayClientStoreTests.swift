import Foundation
import Testing

@testable import Remi

struct AirPlayClientStoreTests {
  private typealias Client = AirPlayClientStore.Client

  private let directory: TemporaryDirectory
  private let fileURL: URL

  init() throws {
    directory = try TemporaryDirectory()
    fileURL = directory.file("clients.json")
  }

  /// A valid Ed25519 public key: 32 bytes in base64.
  private static func publicKey(_ byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
  }

  private static func client(_ deviceID: String, _ name: String, key: UInt8) -> Client {
    Client(deviceID: deviceID, name: name, publicKey: publicKey(key))
  }

  @Test("Knows a paired client's key, and remembers it after relaunching")
  func addAndReload() throws {
    let store = AirPlayClientStore(fileURL: fileURL)
    try store.add(Self.client("AA:BB", "iPhone", key: 1))
    #expect(store.contains(publicKey: Self.publicKey(1)))
    #expect(!store.contains(publicKey: Self.publicKey(2)))

    let reloaded = AirPlayClientStore(fileURL: fileURL)
    #expect(reloaded.contains(publicKey: Self.publicKey(1)))
    #expect(reloaded.pairedClients == [Self.client("AA:BB", "iPhone", key: 1)])
  }

  @Test("Re-pairing with the same key replaces the old entry")
  func sameKeyReplaces() throws {
    let store = AirPlayClientStore(fileURL: fileURL)
    try store.add(Self.client("AA:BB", "Old Name", key: 1))
    try store.add(Self.client("AA:BB", "New Name", key: 1))
    #expect(store.pairedClients == [Self.client("AA:BB", "New Name", key: 1)])
  }

  @Test("Lists one entry per device, its latest pairing, but keeps every key")
  func latestPairingPerDevice() throws {
    let store = AirPlayClientStore(fileURL: fileURL)
    try store.add(Self.client("AA:BB", "iPhone", key: 1))
    try store.add(Self.client("AA:BB", "iPhone 17", key: 2))
    #expect(store.pairedClients == [Self.client("AA:BB", "iPhone 17", key: 2)])
    #expect(store.contains(publicKey: Self.publicKey(1)))
  }

  @Test("Lists devices by name, then by device ID")
  func sortedByName() throws {
    let store = AirPlayClientStore(fileURL: fileURL)
    try store.add(Self.client("3", "iPhone 10", key: 1))
    try store.add(Self.client("2", "iPad", key: 2))
    try store.add(Self.client("1", "iPhone 9", key: 3))
    try store.add(Self.client("0", "iPad", key: 4))
    #expect(store.pairedClients.map(\.deviceID) == ["0", "2", "1", "3"])
  }

  @Test("Removing a device forgets all its keys")
  func remove() throws {
    let store = AirPlayClientStore(fileURL: fileURL)
    try store.add(Self.client("AA:BB", "iPhone", key: 1))
    try store.add(Self.client("AA:BB", "iPhone", key: 2))
    try store.add(Self.client("CC:DD", "iPad", key: 3))
    try store.remove(deviceID: "AA:BB")
    #expect(!store.contains(publicKey: Self.publicKey(1)))
    #expect(!store.contains(publicKey: Self.publicKey(2)))
    #expect(AirPlayClientStore(fileURL: fileURL).pairedClients.map(\.deviceID) == ["CC:DD"])
  }

  @Test(
    "Accepts a client with details at their limits",
    arguments: [
      Client(deviceID: "A", name: "i", publicKey: AirPlayClientStoreTests.publicKey(1)),
      Client(
        deviceID: String(repeating: "a", count: 64), name: String(repeating: "a", count: 255),
        publicKey: AirPlayClientStoreTests.publicKey(1)),
    ])
  func clientAtLimits(_ client: AirPlayClientStore.Client) throws {
    let store = AirPlayClientStore(fileURL: fileURL)
    try store.add(client)
    #expect(AirPlayClientStore(fileURL: fileURL).pairedClients == [client])
  }

  @Test(
    "Refuses a client with invalid details",
    arguments: [
      Client(deviceID: "AA:BB", name: "iPhone", publicKey: "not base64"),
      Client(deviceID: "AA:BB", name: "iPhone", publicKey: Data(count: 31).base64EncodedString()),
      Client(deviceID: "AA:BB", name: "iPhone", publicKey: Data(count: 33).base64EncodedString()),
      Client(deviceID: "AA:BB", name: "", publicKey: AirPlayClientStoreTests.publicKey(1)),
      Client(
        deviceID: "AA:BB", name: String(repeating: "a", count: 256), publicKey: AirPlayClientStoreTests.publicKey(1)),
      Client(deviceID: "", name: "iPhone", publicKey: AirPlayClientStoreTests.publicKey(1)),
      Client(
        deviceID: String(repeating: "a", count: 65), name: "iPhone", publicKey: AirPlayClientStoreTests.publicKey(1)),
    ])
  func invalidClient(_ client: AirPlayClientStore.Client) {
    let store = AirPlayClientStore(fileURL: fileURL)
    #expect {
      try store.add(client)
    } throws: { error in
      (error as? RemiError)?.code == .clientStoreSaveFailed
    }
    #expect(store.pairedClients.isEmpty)
  }

  @Test("Ignores invalid clients in the saved file")
  func invalidClientInFile() throws {
    let valid = Self.client("AA:BB", "iPhone", key: 1)
    let invalid = Client(deviceID: "CC:DD", name: "iPad", publicKey: "short")
    try JSONEncoder().encode([valid, invalid]).write(to: fileURL)
    #expect(AirPlayClientStore(fileURL: fileURL).pairedClients == [valid])
  }

  @Test("A failed save throws and keeps the clients it had")
  func saveFails() throws {
    let store = AirPlayClientStore(fileURL: directory.file("missing/clients.json"))
    #expect {
      try store.add(Self.client("AA:BB", "iPhone", key: 1))
    } throws: { error in
      (error as? RemiError)?.code == .clientStoreSaveFailed
    }
    #expect(!store.contains(publicKey: Self.publicKey(1)))
  }
}
