import AppKit

/// Pairs an Android device for Wireless debugging. On the phone: Settings >
/// Developer options > Wireless debugging > Pair device with pairing code.
@MainActor
enum AndroidPairingPrompt {

  /// Returns the host of the phone that paired, which it connects from next, or nil if none did.
  /// `progress` shows while pairing, and is left open after a pairing that succeeds.
  static func present(adb: Adb, progress: ProgressPrompt) async -> String? {
    NSApp.activate()
    let addressField = NSTextField(string: "")
    addressField.placeholderString = "192.168.1.20:37123"
    let codeField = NSTextField(string: "")
    codeField.placeholderString = "123456"

    let alert = NSAlert()
    alert.messageText = "Pair Android Device"
    alert.informativeText =
      "On the device, open Developer options > Wireless debugging > Pair device with pairing code."
    alert.accessoryView = makeForm(codeField: codeField, addressField: addressField)
    alert.addButton(withTitle: "Pair")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = codeField
    guard alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }

    do {
      let (address, code) = try validate(address: addressField.stringValue, code: codeField.stringValue)
      progress.show()
      // The code goes in on stdin so it never shows up in the process list.
      _ = try await adb.run(["pair", address], input: code)
      return AndroidDevice.host(ofAddress: address)
    } catch {
      progress.close()
      // Cancelling (from the progress prompt, or turning Android off) stops adb, which isn't a failure.
      if !Task.isCancelled {
        Alert.show(error, title: "Pairing Failed")
      }
      return nil
    }
  }

  /// Code first, then address: the order the device shows them in.
  private static func makeForm(codeField: NSTextField, addressField: NSTextField) -> NSView {
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Pairing code:"), codeField],
      [NSTextField(labelWithString: "IP address & port:"), addressField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.rowSpacing = 8
    // The fields stretch to fill the alert's standard width after the labels.
    grid.widthAnchor.constraint(equalToConstant: Alert.accessoryWidth).isActive = true
    grid.frame.size = grid.fittingSize
    return grid
  }

  private static func validate(address: String, code: String) throws -> (address: String, code: String) {
    let address = address.trimmingCharacters(in: .whitespaces)
    let code = code.trimmingCharacters(in: .whitespaces)
    guard
      let match = address.wholeMatch(of: /(?<host>[A-Za-z0-9.\-]{1,253}|\[[0-9A-Fa-f:]{2,39}\]):(?<port>\d{1,5})/),
      let port = Int(match.port), (1...65535).contains(port)
    else {
      throw RemiError(
        .androidPairingInputInvalid, "Enter the IP address and port shown on the device, like 192.168.1.20:37123.")
    }
    guard code.wholeMatch(of: /\d{6}/) != nil else {
      throw RemiError(.androidPairingInputInvalid, "Enter the 6-digit pairing code shown on the device.")
    }
    return (address, code)
  }
}
