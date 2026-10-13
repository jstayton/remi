import Foundation
import dnssd

/// Resolves a Bonjour service instance to an IPv4 "address:port" from its DNS-SD records,
/// without connecting to it. Waits for the service to appear if it isn't advertised yet.
@MainActor
final class BonjourResolver {
  private var serviceRef: DNSServiceRef?
  private var continuation: CheckedContinuation<String?, Never>?
  private var port: UInt16 = 0

  /// Returns nil when cancelled or when DNS-SD reports an error.
  func resolve(name: String, type: String) async -> String? {
    cancel()
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      var ref: DNSServiceRef?
      let error = DNSServiceResolve(&ref, 0, 0, name, type, "local.", Self.resolveReply, context)
      start(ref, error: error)
    }
  }

  func cancel() {
    finish(nil)
  }

  private var context: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(self).toOpaque()
  }

  private func start(_ ref: DNSServiceRef?, error: DNSServiceErrorType) {
    guard error == kDNSServiceErr_NoError, let ref else {
      Log.android.error("DNS-SD lookup failed to start (\(error, privacy: .public))")
      finish(nil)
      return
    }
    serviceRef = ref
    DNSServiceSetDispatchQueue(ref, .main)
  }

  private func finish(_ address: String?) {
    stopLookup()
    continuation?.resume(returning: address)
    continuation = nil
  }

  private func stopLookup() {
    if let serviceRef {
      DNSServiceRefDeallocate(serviceRef)
    }
    serviceRef = nil
  }

  /// The SRV record gives a host name and port; the host's address is a second lookup.
  private func didResolve(hostTarget: String, port: UInt16) {
    self.port = port
    stopLookup()
    var ref: DNSServiceRef?
    let error = DNSServiceGetAddrInfo(
      &ref, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4), hostTarget, Self.addressReply, context)
    start(ref, error: error)
  }

  private func didFindAddress(_ host: String) {
    finish("\(host):\(port)")
  }

  private func didFail(_ error: DNSServiceErrorType) {
    Log.android.error("DNS-SD lookup failed (\(error, privacy: .public))")
    finish(nil)
  }

  // Both replies arrive on the main queue (DNSServiceSetDispatchQueue). Pointers are turned
  // into plain values before hopping onto the main actor.
  private static let resolveReply: DNSServiceResolveReply = { _, _, _, error, _, hostTarget, port, _, _, context in
    let contextBits = UInt(bitPattern: context)
    let host = hostTarget.map { String(cString: $0) }
    let port = UInt16(bigEndian: port)
    MainActor.assumeIsolated {
      guard let resolver = resolver(from: contextBits) else {
        return
      }
      guard error == kDNSServiceErr_NoError, let host else {
        resolver.didFail(error)
        return
      }
      resolver.didResolve(hostTarget: host, port: port)
    }
  }

  private static let addressReply: DNSServiceGetAddrInfoReply = { _, _, _, error, _, address, _, context in
    let contextBits = UInt(bitPattern: context)
    let host = address.flatMap(ipv4String)
    MainActor.assumeIsolated {
      guard let resolver = resolver(from: contextBits) else {
        return
      }
      guard error == kDNSServiceErr_NoError else {
        resolver.didFail(error)
        return
      }
      // A reply that isn't an IPv4 address is skipped; the lookup keeps waiting for one.
      if let host {
        resolver.didFindAddress(host)
      }
    }
  }

  private nonisolated static func resolver(from contextBits: UInt) -> BonjourResolver? {
    UnsafeMutableRawPointer(bitPattern: contextBits).map {
      Unmanaged<BonjourResolver>.fromOpaque($0).takeUnretainedValue()
    }
  }

  private nonisolated static func ipv4String(_ address: UnsafePointer<sockaddr>) -> String? {
    guard address.pointee.sa_family == sa_family_t(AF_INET) else {
      return nil
    }
    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    guard inet_ntop(AF_INET, &ipv4, &host, socklen_t(host.count)) != nil else {
      return nil
    }
    return String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
  }
}
