import AVFoundation
import CoreImage

/// Re-encodes a recording whose frame size changed partway (the device rotated) onto one
/// canvas that fits every size, each frame centered on black. AVFoundation's players
/// (QuickTime Player, Photos) stretch every frame to the first frame's size otherwise.
///
/// The frames are copied on `queue`, one at a time. Only `isCancelled` is touched elsewhere.
final class Letterboxer: @unchecked Sendable {
  /// The reading and writing ends of the copy. AVFoundation doesn't mark them Sendable, but
  /// once copying starts they're only used on `queue`.
  private struct Pipeline: @unchecked Sendable {
    let output: AVAssetReaderTrackOutput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let writer: AVAssetWriter

    var input: AVAssetWriterInput { adaptor.assetWriterInput }
  }

  /// Re-encoding loses a little, so it gets more bits than the device used. The black bars cost
  /// almost nothing.
  private static let bitRateMultiplier = 2
  private static let minimumBitRate = 8 * 1000 * 1000
  /// Progress is reported in steps this big, so the main thread isn't flooded with updates.
  private static let progressStep = 0.01

  private let source: URL
  private let destination: URL
  private let canvasSize: CGSize
  private let queue = DispatchQueue(label: "com.jstayton.remi.letterboxer")
  private let context = CIContext(options: [.workingColorSpace: NSNull()])
  private let failsHalfway: Bool
  private let onProgress: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var isCancelled = false
  private var reportedProgress = 0.0

  /// `onProgress` runs on a background queue with the fraction done, from 0 to 1. `failsHalfway`
  /// fakes a failure, for testing (see Preferences.recordingTestFailure).
  init(
    source: URL, destination: URL, canvasSize: CGSize, failsHalfway: Bool = false,
    onProgress: @escaping @Sendable (Double) -> Void
  ) {
    self.source = source
    self.destination = destination
    self.canvasSize = canvasSize
    self.failsHalfway = failsHalfway
    self.onProgress = onProgress
  }

  /// Throws CancellationError if its task is cancelled. A failure can leave part of a movie at
  /// `destination`, which is the caller's to clean up.
  func run() async throws {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw RemiError(.recordingFailed, "The recording has no video")
    }
    let (duration, sourceBitRate) = (try await asset.load(.duration), try await track.load(.estimatedDataRate))

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)

    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    let bitRate = max(Self.minimumBitRate, Int(sourceBitRate) * Self.bitRateMultiplier)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: canvasSize.width,
        AVVideoHeightKey: canvasSize.height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
      ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: canvasSize.width,
        kCVPixelBufferHeightKey as String: canvasSize.height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ])
    writer.add(input)

    guard reader.startReading() else {
      throw RemiError(.recordingFailed, "Couldn't read the recording", cause: reader.error)
    }
    guard writer.startWriting() else {
      throw RemiError(.recordingFailed, "Couldn't start writing \(destination.lastPathComponent)", cause: writer.error)
    }
    writer.startSession(atSourceTime: .zero)
    do {
      try await withTaskCancellationHandler {
        try await copyFrames(Pipeline(output: output, adaptor: adaptor, writer: writer), duration: duration)
      } onCancel: {
        lock.withLock { isCancelled = true }
      }
      guard reader.status == .completed else {
        throw RemiError(.recordingFailed, "Couldn't read the recording", cause: reader.error)
      }
    } catch {
      reader.cancelReading()
      writer.cancelWriting()
      throw error
    }
    // The last frame stays on screen until the end, as in the original.
    writer.endSession(atSourceTime: duration)
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw RemiError(.recordingFailed, "Couldn't save \(destination.lastPathComponent)", cause: writer.error)
    }
  }

  private func copyFrames(_ pipeline: Pipeline, duration: CMTime) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      // Marking the input finished stops these callbacks, so the continuation resumes once.
      pipeline.input.requestMediaDataWhenReady(on: queue) { [self] in
        let input = pipeline.input
        while input.isReadyForMoreMediaData {
          guard !lock.withLock({ isCancelled }) else {
            input.markAsFinished()
            continuation.resume(throwing: CancellationError())
            return
          }
          guard let sample = pipeline.output.copyNextSampleBuffer() else {
            input.markAsFinished()
            continuation.resume()
            return
          }
          do {
            let fraction = sample.presentationTimeStamp.seconds / duration.seconds
            if failsHalfway && fraction >= 0.5 {
              throw RemiError(.recordingFailed, "A test failure (recordingTestFailure is letterbox)")
            }
            try append(sample, to: pipeline)
            reportProgress(fraction)
          } catch {
            input.markAsFinished()
            continuation.resume(throwing: error)
            return
          }
        }
      }
    }
  }

  private func reportProgress(_ fraction: Double) {
    guard fraction - reportedProgress >= Self.progressStep else {
      return
    }
    reportedProgress = fraction
    onProgress(min(1, fraction))
  }

  private func append(_ sample: CMSampleBuffer, to pipeline: Pipeline) throws {
    guard let frame = sample.imageBuffer else {
      return
    }
    var canvas: CVPixelBuffer?
    guard let pool = pipeline.adaptor.pixelBufferPool,
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &canvas) == kCVReturnSuccess, let canvas
    else {
      throw RemiError(.recordingFailed, "Couldn't allocate a video frame")
    }
    let image = CIImage(cvPixelBuffer: frame)
    let offset = CGPoint(
      x: ((canvasSize.width - image.extent.width) / 2).rounded(),
      y: ((canvasSize.height - image.extent.height) / 2).rounded())
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let letterboxed = image.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
      .composited(over: CIImage(color: .black).cropped(to: canvasRect))
    context.render(letterboxed, to: canvas, bounds: canvasRect, colorSpace: nil)
    guard pipeline.adaptor.append(canvas, withPresentationTime: sample.presentationTimeStamp) else {
      throw RemiError(
        .recordingFailed, "Couldn't write to \(destination.lastPathComponent)", cause: pipeline.writer.error)
    }
  }
}
