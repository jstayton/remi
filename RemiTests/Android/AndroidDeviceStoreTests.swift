import Foundation
import Testing

@testable import Remi

@MainActor
struct AndroidDeviceStoreTests {
  private typealias Device = AndroidDeviceStore.Device

  private let directory: TemporaryDirectory
  private let fileURL: URL

  init() throws {
    directory = try TemporaryDirectory()
    fileURL = directory.file("devices.json")
  }

  @Test("Remembers devices across relaunches, sorted by model")
  func rememberAndReload() {
    let store = AndroidDeviceStore(fileURL: fileURL)
    store.remember(Device(hardwareSerial: "2", model: "Pixel 10"))
    store.remember(Device(hardwareSerial: "1", model: "Pixel 9"))
    store.remember(Device(hardwareSerial: "3", model: "Galaxy S26"))
    let expected = ["Galaxy S26", "Pixel 9", "Pixel 10"]
    #expect(store.devices.map(\.model) == expected)
    #expect(AndroidDeviceStore(fileURL: fileURL).devices.map(\.model) == expected)
  }

  @Test("A renamed device replaces its old entry")
  func rename() {
    let store = AndroidDeviceStore(fileURL: fileURL)
    store.remember(Device(hardwareSerial: "1", model: "Pixel"))
    store.remember(Device(hardwareSerial: "1", model: "Pixel 9"))
    #expect(store.devices == [Device(hardwareSerial: "1", model: "Pixel 9")])
  }

  @Test("Forgetting a device removes it")
  func forget() {
    let store = AndroidDeviceStore(fileURL: fileURL)
    store.remember(Device(hardwareSerial: "1", model: "Pixel 9"))
    store.remember(Device(hardwareSerial: "2", model: "Pixel 10"))
    store.forget(hardwareSerial: "1")
    #expect(store.devices.map(\.hardwareSerial) == ["2"])
    #expect(AndroidDeviceStore(fileURL: fileURL).devices.map(\.hardwareSerial) == ["2"])
  }

  @Test(
    "Remembers a device with details at their limits",
    arguments: [
      Device(hardwareSerial: "1", model: "P"),
      Device(hardwareSerial: String(repeating: "a", count: 128), model: String(repeating: "a", count: 255)),
    ])
  func deviceAtLimits(_ device: AndroidDeviceStore.Device) {
    AndroidDeviceStore(fileURL: fileURL).remember(device)
    #expect(AndroidDeviceStore(fileURL: fileURL).devices == [device])
  }

  @Test(
    "Ignores a device with invalid details",
    arguments: [
      Device(hardwareSerial: "", model: "Pixel 9"),
      Device(hardwareSerial: String(repeating: "a", count: 129), model: "Pixel 9"),
      Device(hardwareSerial: "1", model: ""),
      Device(hardwareSerial: "1", model: String(repeating: "a", count: 256)),
    ])
  func invalidDevice(_ device: AndroidDeviceStore.Device) {
    let store = AndroidDeviceStore(fileURL: fileURL)
    store.remember(device)
    #expect(store.devices.isEmpty)
  }

  @Test("A failed save keeps the device listed until relaunch")
  func saveFails() {
    let store = AndroidDeviceStore(fileURL: directory.file("missing/devices.json"))
    store.remember(Device(hardwareSerial: "1", model: "Pixel 9"))
    #expect(store.devices.count == 1)
  }
}
