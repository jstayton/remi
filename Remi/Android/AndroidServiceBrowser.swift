import Foundation
import Network

/// Finds phones advertising Wireless debugging over Bonjour and resolves their addresses.
/// adb's own discovery can take over a minute, so Remi finds phones itself.
@MainActor
final class AndroidServiceBrowser {
  struct Service {
    /// For example "192.168.1.20:37123".
    let address: String
    /// The phone's `ro.serialno`, from its service name: "adb-<serial>-<suffix>".
    let hardwareSerial: String?
  }

  private static let serviceType = "_adb-tls-connect._tcp"
  private static let resolveTimeout = Duration.seconds(5)
  /// Lookups fail for a moment after launch while macOS checks Local Network access, and
  /// Bonjour won't report the phone again, so failed lookups are retried while it's visible.
  private static let resolveAttempts = 10
  private static let resolveRetryDelay = Duration.seconds(3)

  var onServiceFound: ((Service) -> Void)?

  private var browser: NWBrowser?
  private var visibleEndpoints: Set<NWEndpoint> = []

  func start() {
    guard browser == nil else {
      return
    }
    let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] _, changes in
      var added: [NWEndpoint] = []
      var removed: [NWEndpoint] = []
      for change in changes {
        switch change {
        case .added(let result): added.append(result.endpoint)
        case .removed(let result): removed.append(result.endpoint)
        default: break
        }
      }
      Task { @MainActor in
        self?.visibleEndpoints.subtract(removed)
        for endpoint in added {
          self?.visibleEndpoints.insert(endpoint)
          self?.resolve(endpoint, attempt: 1)
        }
      }
    }
    browser.stateUpdateHandler = { state in
      if case .failed(let error) = state {
        Log.android.error("Wireless debugging discovery failed: \(error, privacy: .public)")
      }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  func stop() {
    browser?.cancel()
    browser = nil
    visibleEndpoints.removeAll()
  }

  /// Reports every visible phone again, such as one that was just paired.
  func rediscover() {
    guard browser != nil else {
      return
    }
    stop()
    start()
  }

  /// Network.framework only reveals a service's address by connecting to it. The
  /// connection is dropped as soon as the address is known.
  private func resolve(_ endpoint: NWEndpoint, attempt: Int) {
    let hardwareSerial = Self.hardwareSerial(from: endpoint)
    let parameters = NWParameters.tcp
    if let options = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      options.version = .v4
    }
    let connection = NWConnection(to: endpoint, using: parameters)
    var isFinished = false
    let finish: @MainActor (String?) -> Void = { [weak self] address in
      guard !isFinished else {
        return
      }
      isFinished = true
      connection.cancel()
      if let address {
        self?.onServiceFound?(Service(address: address, hardwareSerial: hardwareSerial))
      } else {
        self?.retryResolve(endpoint, after: attempt)
      }
    }
    connection.stateUpdateHandler = { [weak connection] state in
      switch state {
      case .ready:
        let address = connection?.currentPath?.remoteEndpoint.flatMap(Self.address)
        Task { @MainActor in finish(address) }
      case .failed, .waiting:
        Task { @MainActor in finish(nil) }
      default:
        break
      }
    }
    connection.start(queue: .main)
    Task {
      try? await Task.sleep(for: Self.resolveTimeout)
      finish(nil)
    }
  }

  private func retryResolve(_ endpoint: NWEndpoint, after attempt: Int) {
    guard attempt < Self.resolveAttempts else {
      Log.android.info("Gave up looking up a Wireless debugging phone's address")
      return
    }
    Task {
      try? await Task.sleep(for: Self.resolveRetryDelay)
      if visibleEndpoints.contains(endpoint) {
        resolve(endpoint, attempt: attempt + 1)
      }
    }
  }

  private static func hardwareSerial(from endpoint: NWEndpoint) -> String? {
    guard case .service(let name, _, _, _) = endpoint,
      let match = name.wholeMatch(of: /adb-(?<serial>[A-Za-z0-9]{1,64})-[A-Za-z0-9]+/)
    else {
      return nil
    }
    return String(match.serial)
  }

  private nonisolated static func address(of endpoint: NWEndpoint) -> String? {
    guard case .hostPort(let host, let port) = endpoint, case .ipv4(let ipv4) = host else {
      return nil
    }
    // Drop any interface scope, like "%en0".
    let hostString = "\(ipv4)".split(separator: "%").first.map(String.init) ?? "\(ipv4)"
    return "\(hostString):\(port.rawValue)"
  }
}
