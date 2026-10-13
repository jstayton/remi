import AVFoundation
import AppKit

/// Shows decoded video inside a thin bezel. The top of the bezel is as tall as the
/// title bar, so the window buttons sit above the video instead of over it.
final class MirrorView: NSView {
  /// The capture rings sit in the bezel just outside the screen, so they never cover the video.
  private static let captureRingWidth: CGFloat = 2
  private static let captureFlashDuration: TimeInterval = 0.6
  private static let recordingPulseDuration: TimeInterval = 1
  private static let recordingPulseMinimumOpacity: Float = 0.25

  /// The black screen with its grey edge. The video sits inside it, so fading the video
  /// out leaves a dark screen rather than a hole in the bezel.
  private let screenView = NSView()
  private let screenLayer = CALayer()
  private let displayLayer = AVSampleBufferDisplayLayer()
  /// Only screenshots use it, so it's made the first time one is taken.
  private lazy var imageContext = CIContext()
  /// Pulses red while recording.
  private let recordingRing = MirrorView.makeCaptureRing(color: .systemRed)
  /// Flashes white for a screenshot, over the recording ring if it's showing.
  private let flashRing = MirrorView.makeCaptureRing(color: .white)

  var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

  /// Set to the window's title bar height so the buttons have room.
  var titleBarHeight: CGFloat = 28 {
    didSet { needsLayout = true }
  }

  var isRecording = false {
    didSet { updateRecordingRing() }
  }

  /// The space between the window's edges and the video.
  var videoInsets: NSEdgeInsets {
    Bezel.insets(titleBarHeight: titleBarHeight)
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Bezel.color.cgColor

    Bezel.styleScreen(screenLayer)
    displayLayer.videoGravity = .resizeAspect
    // The video layer doesn't honor its parent's mask, so it's rounded the same way itself.
    displayLayer.cornerRadius = Bezel.screenCornerRadius
    displayLayer.cornerCurve = .continuous
    displayLayer.masksToBounds = true
    screenLayer.addSublayer(displayLayer)
    screenView.layer = screenLayer
    screenView.wantsLayer = true
    addSubview(screenView)

    addSubview(recordingRing)
    addSubview(flashRing)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var mouseDownCanMoveWindow: Bool { true }

  override func layout() {
    super.layout()
    let insets = videoInsets
    screenView.frame = NSRect(
      x: insets.left, y: insets.bottom,
      width: max(0, bounds.width - insets.left - insets.right),
      height: max(0, bounds.height - insets.top - insets.bottom))
    let ringFrame = screenView.frame.insetBy(dx: -Self.captureRingWidth, dy: -Self.captureRingWidth)
    recordingRing.frame = ringFrame
    flashRing.frame = ringFrame
    // The video follows the screen exactly; an implicit animation would lag behind it.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = screenLayer.bounds
    CATransaction.commit()
  }

  /// The frame on screen right now, at the stream's full resolution and without the bezel.
  func displayedFrame() -> CGImage? {
    guard let pixelBuffer = renderer.displayedPixelBuffer() else {
      return nil
    }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    return imageContext.createCGImage(image, from: image.extent)
  }

  func flash() {
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1
    animation.toValue = 0
    animation.duration = Self.captureFlashDuration
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    flashRing.layer?.add(animation, forKey: "flash")
  }

  /// Fades the video in or out over the black screen, returning when the fade finishes.
  func fadeVideo(to opacity: Float, duration: TimeInterval) async {
    await withCheckedContinuation { continuation in
      CATransaction.begin()
      CATransaction.setAnimationDuration(duration)
      CATransaction.setCompletionBlock { continuation.resume() }
      displayLayer.opacity = opacity
      CATransaction.commit()
    }
  }

  /// The pulse is skipped when macOS is set to reduce motion, leaving the ring steady.
  private func updateRecordingRing() {
    recordingRing.alphaValue = isRecording ? 1 : 0
    guard let layer = recordingRing.layer else {
      return
    }
    layer.removeAnimation(forKey: "pulse")
    guard isRecording, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      return
    }
    let pulse = CABasicAnimation(keyPath: "opacity")
    pulse.fromValue = 1
    pulse.toValue = Self.recordingPulseMinimumOpacity
    pulse.duration = Self.recordingPulseDuration
    pulse.autoreverses = true
    pulse.repeatCount = .infinity
    pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(pulse, forKey: "pulse")
  }

  /// A ring around the screen, concentric with its corners. Hidden until it's animated or shown.
  private static func makeCaptureRing(color: NSColor) -> NSView {
    let ring = NSView()
    ring.wantsLayer = true
    ring.layer?.borderWidth = captureRingWidth
    ring.layer?.borderColor = color.cgColor
    ring.layer?.cornerRadius = Bezel.screenCornerRadius + captureRingWidth
    // macOS draws window corners as continuous curves, not circular arcs, and so does the screen.
    ring.layer?.cornerCurve = .continuous
    ring.alphaValue = 0
    return ring
  }
}
