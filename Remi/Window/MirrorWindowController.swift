import AppKit
import CoreMedia

/// One window per mirroring session, hidden until the first frame. The bezel is a fixed size,
/// so `contentAspectRatio` can't lock the video's aspect; resizing and zooming do it here.
/// Each device's window reopens where it was last, keyed by `deviceKey`.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
  private static let initialScreenHeightFraction = 0.75
  /// Resizing to within this of the default size snaps to it, so it's easy to get back to.
  private static let defaultSizeSnapDistance: CGFloat = 24
  private static let minimumVideoWidth: CGFloat = 120
  private static let rotationFadeDuration: TimeInterval = 0.12
  private static let rotationReshapeDuration: TimeInterval = 0.22

  private let deviceKey: String
  private let sink: VideoSink
  private let mirrorView: MirrorView
  private let onUserClose: () -> Void
  private var videoSize: CGSize?
  private var isClosingForSource = false
  private var rotation: Task<Void, Never>?
  private var isSnappedToDefaultSize = false
  private var liveResizeStartSize: CGSize?
  private var recording: Recording?

  init(title: String, deviceKey: String, sink: VideoSink, floatsOnTop: Bool, onUserClose: @escaping () -> Void) {
    self.deviceKey = deviceKey
    self.sink = sink
    self.onUserClose = onUserClose
    let view = MirrorView()
    mirrorView = view
    let window = MirrorWindow(contentView: view)
    window.title = title
    window.setFloatsOnTop(floatsOnTop)
    view.titleBarHeight = window.frame.height - window.contentLayoutRect.height
    super.init(window: window)
    window.delegate = self
    sink.attach(renderer: view.renderer) { [weak self] size in
      Task { @MainActor in self?.updateVideoSize(size) }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  var mirrorWindow: MirrorWindow? { window as? MirrorWindow }

  func bringToFront() {
    guard videoSize != nil, let window else {
      return
    }
    window.makeKeyAndOrderFront(nil)
    // macOS can refuse activation when the window appears a moment after the click
    // (or, for iOS, with no click at all), so make sure the window is on top anyway.
    window.orderFrontRegardless()
    DockPresence.update()
    NSApp.activate()
  }

  /// File > Save Screenshot (⌘S), sent here through the responder chain.
  @objc func saveScreenshot(_ sender: Any?) {
    takeScreenshot(failureTitle: "Couldn't Save Screenshot") { image in
      let url = try Screenshot.save(image, deviceName: self.window?.title ?? "Device")
      Log.app.info("Saved a screenshot to \(url.path(percentEncoded: false), privacy: .private)")
    }
  }

  /// File > Copy Screenshot (⌘C).
  @objc func copyScreenshot(_ sender: Any?) {
    takeScreenshot(failureTitle: "Couldn't Copy Screenshot") { image in
      try Screenshot.copy(image)
    }
  }

  /// File > Start Recording / Stop Recording (⌘R).
  @objc func toggleRecording(_ sender: Any?) {
    if recording != nil {
      stopRecording()
    } else {
      startRecording()
    }
  }

  /// Whether any window is recording, or any recording is still being saved.
  static var hasRecordings: Bool {
    RecordingSaver.isSaving || openControllers.contains { $0.recording != nil }
  }

  /// Stops every recording and waits until all of them are saved, for quitting.
  static func finishRecordings() async {
    for controller in openControllers {
      controller.stopRecording()
    }
    await RecordingSaver.waitUntilDone()
  }

  private static var openControllers: [MirrorWindowController] {
    NSApp.windows.compactMap { $0.windowController as? MirrorWindowController }
  }

  /// Saves the recording, if there is one. Also called when the window closes and when Remi quits.
  private func stopRecording() {
    guard let recording = sink.stopRecording() else {
      return
    }
    self.recording = nil
    mirrorView.isRecording = false
    RecordingSaver.save(recording, endingAt: CMClockGetTime(CMClockGetHostTimeClock()))
  }

  /// Window > Reset Size (⌘0): back to the size a device's first window opens at, around its center.
  @objc func resetSize(_ sender: Any?) {
    guard let window, let videoSize, let screen = window.screen ?? NSScreen.main else {
      return
    }
    let size = defaultWindowSize(forVideo: videoSize, on: screen)
    let frame = NSRect(
      x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2, width: size.width,
      height: size.height)
    window.setFrame(keptOnScreen(frame, screen: screen), display: true, animate: true)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(resetSize(_:)):
      return videoSize != nil
    case #selector(toggleRecording(_:)):
      menuItem.title = recording == nil ? "Start Recording" : "Stop Recording"
      return videoSize != nil
    case #selector(saveScreenshot(_:)), #selector(copyScreenshot(_:)):
      return videoSize != nil
    default:
      return true
    }
  }

  private func takeScreenshot(failureTitle: String, _ handle: (CGImage) throws -> Void) {
    guard let image = mirrorView.displayedFrame() else {
      NSSound.beep()
      return
    }
    mirrorView.flash()
    Screenshot.playSound()
    do {
      try handle(image)
    } catch {
      Alert.show(error, title: failureTitle)
    }
  }

  private func startRecording() {
    do {
      let recording = try Recording(
        deviceName: window?.title ?? "Device", startTime: CMClockGetTime(CMClockGetHostTimeClock())
      ) { [weak self] _ in
        Task { @MainActor in self?.stopRecording() }
      }
      self.recording = recording
      mirrorView.isRecording = true
      sink.startRecording(recording)
    } catch {
      Alert.show(error, title: "Couldn't Start Recording")
    }
  }

  /// Closes the window because the session ended, without reporting a user close.
  func closeForSource() {
    isClosingForSource = true
    close()
  }

  func windowWillClose(_ notification: Notification) {
    stopRecording()
    sink.detach()
    // The window is still visible here, so check once it has closed.
    Task { @MainActor in DockPresence.update() }
    if !isClosingForSource {
      onUserClose()
    }
  }

  /// Keeps the video at the phone's aspect ratio, following whichever edge is being dragged.
  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard let videoSize else {
      return frameSize
    }
    let aspect = videoSize.width / videoSize.height
    // Compared with the size the drag started at, not the current one: that changes with every
    // event, which made a corner drag flip between following width and height, and jitter.
    let start = liveResizeStartSize ?? sender.frame.size
    let isDraggingWidth: Bool
    if frameSize.height == start.height || frameSize.width == start.width {
      isDraggingWidth = frameSize.height == start.height
    } else {
      // A corner follows whichever way it's stretched more. Where they cross, both agree.
      isDraggingWidth = abs(frameSize.width / start.width - 1) >= abs(frameSize.height / start.height - 1)
    }
    let size: CGSize
    if isDraggingWidth {
      let videoWidth = max(Self.minimumVideoWidth, frameSize.width - horizontalInset)
      size = windowSize(forVideo: CGSize(width: videoWidth, height: videoWidth / aspect))
    } else {
      let videoHeight = max(Self.minimumVideoWidth / aspect, frameSize.height - verticalInset)
      size = windowSize(forVideo: CGSize(width: videoHeight * aspect, height: videoHeight))
    }
    return snappedToDefaultSize(size, window: sender)
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    liveResizeStartSize = window?.frame.size
    // Starting from the default size isn't snapping to it, so it shouldn't tap.
    guard let window, let videoSize, let screen = window.screen else {
      return
    }
    isSnappedToDefaultSize = window.frame.size == defaultWindowSize(forVideo: videoSize, on: screen)
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    liveResizeStartSize = nil
    saveFrame()
  }

  /// A trackpad taps as the window snaps, like an alignment guide.
  private func snappedToDefaultSize(_ size: CGSize, window: NSWindow) -> CGSize {
    guard let videoSize, let screen = window.screen else {
      return size
    }
    let defaultSize = defaultWindowSize(forVideo: videoSize, on: screen)
    let isNear = abs(size.height - defaultSize.height) <= Self.defaultSizeSnapDistance
    if isNear && !isSnappedToDefaultSize {
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    isSnappedToDefaultSize = isNear
    return isNear ? defaultSize : size
  }

  /// The green button zooms to the largest size that fits the screen.
  func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
    guard let videoSize else {
      return newFrame
    }
    let size = fittedWindowSize(forVideo: videoSize, in: newFrame.size)
    return NSRect(
      x: newFrame.midX - size.width / 2, y: newFrame.midY - size.height / 2, width: size.width, height: size.height)
  }

  private var horizontalInset: CGFloat { mirrorView.videoInsets.left + mirrorView.videoInsets.right }
  private var verticalInset: CGFloat { mirrorView.videoInsets.top + mirrorView.videoInsets.bottom }

  private func windowSize(forVideo video: CGSize) -> CGSize {
    CGSize(width: (video.width + horizontalInset).rounded(), height: (video.height + verticalInset).rounded())
  }

  /// The largest window that fits `bounds` while showing the video at its aspect ratio.
  private func fittedWindowSize(forVideo video: CGSize, in bounds: CGSize) -> CGSize {
    let scale = min(
      (bounds.width - horizontalInset) / video.width, (bounds.height - verticalInset) / video.height)
    return windowSize(forVideo: CGSize(width: video.width * scale, height: video.height * scale))
  }

  private func updateVideoSize(_ size: CGSize) {
    guard let window, size.width > 0, size.height > 0, size != videoSize else {
      // Back to the size the window already has, so there's nothing to reshape.
      sink.resumeAfterRotation()
      return
    }
    let isFirstFrame = videoSize == nil
    videoSize = size
    guard let screen = window.screen ?? NSScreen.main else {
      return
    }
    if isFirstFrame {
      window.setFrame(savedFrame(for: size) ?? initialFrame(for: size, on: screen), display: true)
      bringToFront()
    } else {
      rotate(window, to: rotatedFrame(for: size, from: window.frame, on: screen))
    }
  }

  /// The sink holds new-orientation frames meanwhile, so the old picture fades out, the window
  /// reshapes on a black screen (nothing to stretch), and the new picture fades in.
  private func rotate(_ window: NSWindow, to frame: NSRect) {
    // A newer rotation takes over from wherever this one is, and always ends by fading in.
    rotation?.cancel()
    rotation = Task {
      await mirrorView.fadeVideo(to: 0, duration: Self.rotationFadeDuration)
      guard !Task.isCancelled else {
        return
      }
      await NSAnimationContext.runAnimationGroup { context in
        context.duration = Self.rotationReshapeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrame(frame, display: true)
      }
      guard !Task.isCancelled else {
        return
      }
      sink.resumeAfterRotation()
      await mirrorView.fadeVideo(to: 1, duration: Self.rotationFadeDuration)
    }
  }

  /// The device's last window, reshaped for the video's orientation now, the way rotation does.
  /// Nil the first time a device mirrors.
  private func savedFrame(for size: CGSize) -> NSRect? {
    guard let saved = Preferences.windowFrame(forDevice: deviceKey) else {
      return nil
    }
    // A display that's gone since leaves the window on the main one.
    let center = CGPoint(x: saved.midX, y: saved.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else {
      return nil
    }
    return rotatedFrame(for: size, from: saved, on: screen)
  }

  private func saveFrame() {
    guard let window, videoSize != nil, !window.inLiveResize else {
      return
    }
    Preferences.setWindowFrame(window.frame, forDevice: deviceKey)
  }

  func windowDidMove(_ notification: Notification) {
    saveFrame()
  }

  func windowDidResize(_ notification: Notification) {
    saveFrame()
  }

  /// The largest window for the video that fits within 75% of the screen's height.
  private func defaultWindowSize(forVideo video: CGSize, on screen: NSScreen) -> CGSize {
    let visible = screen.visibleFrame
    let bounds = CGSize(width: visible.width, height: visible.height * Self.initialScreenHeightFraction)
    return fittedWindowSize(forVideo: video, in: bounds)
  }

  private func initialFrame(for size: CGSize, on screen: NSScreen) -> NSRect {
    let visible = screen.visibleFrame
    let windowSize = defaultWindowSize(forVideo: size, on: screen)
    let origin = CGPoint(x: visible.midX - windowSize.width / 2, y: visible.midY - windowSize.height / 2)
    return NSRect(origin: origin, size: windowSize)
  }

  /// Keeps the video's area and the window's center when the phone rotates, then
  /// nudges the window back on screen.
  private func rotatedFrame(for size: CGSize, from frame: NSRect, on screen: NSScreen) -> NSRect {
    let visible = screen.visibleFrame
    let videoArea = (frame.width - horizontalInset) * (frame.height - verticalInset)
    let aspect = size.width / size.height
    let videoHeight = (videoArea / aspect).squareRoot()
    var windowSize = windowSize(forVideo: CGSize(width: videoHeight * aspect, height: videoHeight))
    if windowSize.width > visible.width || windowSize.height > visible.height {
      windowSize = fittedWindowSize(forVideo: size, in: visible.size)
    }
    let newFrame = NSRect(
      x: frame.midX - windowSize.width / 2, y: frame.midY - windowSize.height / 2,
      width: windowSize.width, height: windowSize.height)
    return keptOnScreen(newFrame, screen: screen)
  }

  /// Nudges `frame` back within the screen's visible area, keeping its size.
  private func keptOnScreen(_ frame: NSRect, screen: NSScreen) -> NSRect {
    let visible = screen.visibleFrame
    var frame = frame
    frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
    return frame
  }
}
