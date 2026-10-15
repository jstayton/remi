import Foundation

/// iPhones that completed PIN pairing, identified by their Ed25519 public keys.
/// UxPlay asks from its own threads whether a returning client's key is known.
final class AirPlayClientStore: @unchecked Sendable {
  struct Client: Codable, Equatable {
    let deviceID: String
    let name: String
    let publicKey: String
  }

  private let lock = NSLock()
  private let file: JSONFile<Client>
  private var clients: [Client]

  init(fileURL: URL) {
    file = JSONFile(url: fileURL, isValid: Self.isValid)
    clients = file.load()
  }

  /// One entry per device, keeping its most recent pairing, sorted by name.
  var pairedClients: [Client] {
    let clients = lock.withLock { self.clients }
    var latestByDeviceID: [String: Client] = [:]
    for client in clients {
      latestByDeviceID[client.deviceID] = client
    }
    // By device ID too, so devices with the same name keep a stable order.
    return latestByDeviceID.values.sorted {
      switch $0.name.localizedStandardCompare($1.name) {
      case .orderedSame: $0.deviceID < $1.deviceID
      case let order: order == .orderedAscending
      }
    }
  }

  func contains(publicKey: String) -> Bool {
    lock.withLock { clients.contains { $0.publicKey == publicKey } }
  }

  func add(_ client: Client) throws {
    guard Self.isValid(client) else {
      throw RemiError(.clientStoreSaveFailed, "Refused to save an AirPlay client with invalid details")
    }
    try lock.withLock {
      var updated = clients.filter { $0.publicKey != client.publicKey }
      updated.append(client)
      try save(updated)
      clients = updated
    }
  }

  /// Removes every pairing for the device, so it needs a new PIN to connect again.
  func remove(deviceID: String) throws {
    try lock.withLock {
      let updated = clients.filter { $0.deviceID != deviceID }
      try save(updated)
      clients = updated
    }
  }

  private func save(_ clients: [Client]) throws {
    do {
      try file.save(clients)
    } catch {
      throw RemiError(.clientStoreSaveFailed, "Remi couldn't save its list of paired devices.", cause: error)
    }
  }

  /// Public keys are 32-byte Ed25519 keys in base64, which is always 44 characters.
  @Sendable private static func isValid(_ client: Client) -> Bool {
    client.publicKey.count == 44
      && Data(base64Encoded: client.publicKey)?.count == 32
      && (1...255).contains(client.name.count)
      && (1...64).contains(client.deviceID.count)
  }
}
