import Testing

@testable import Remi

struct AndroidDeviceTests {
  @Test(
    "Wireless debugging serials are wireless",
    arguments: [
      "adb-1A2B3C4D-xYz123._adb-tls-connect._tcp",
      "192.168.1.20:37015",
      "fe80::1%en0:5555",
      "pixel.local:1",
    ])
  func wirelessSerial(_ serial: String) {
    #expect(AndroidDevice.isWireless(serial: serial))
  }

  @Test(
    "USB and emulator serials aren't wireless",
    arguments: [
      "1A2B3C4D",
      "emulator-5554",
      "192.168.1.20",
      "192.168.1.20:",
      "192.168.1.20:123456",
      "adb-1A2B3C4D._adb-tls-pairing._tcp",
    ])
  func nonWirelessSerial(_ serial: String) {
    #expect(!AndroidDevice.isWireless(serial: serial))
  }

  @Test(
    "The host is everything before the last colon",
    arguments: [
      ("192.168.1.20:37015", "192.168.1.20"),
      ("fe80::1%en0:5555", "fe80::1%en0"),
      ("192.168.1.20", "192.168.1.20"),
      ("", ""),
    ])
  func host(address: String, expected: String) {
    #expect(AndroidDevice.host(ofAddress: address) == expected)
  }
}
