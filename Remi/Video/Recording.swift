import AVFoundation

/// Writes a session's H.264 into a QuickTime movie as-is, without re-encoding. Frames are
/// timed by when they arrived, so playback matches what was on screen, pauses included.
///
/// A rotation changes the frame size mid-track, which AVFoundation's players (QuickTime
/// Player, Photos) stretch to the first size. So a recording with a rotation is letterboxed
/// when it finishes, which re-encodes it, and every other recording is kept as it arrived.
///
/// Frames queue here and go to the writer as fast as it takes them, so a burst (like every frame
/// since the last key frame, when recording starts) isn't dropped. VideoSink calls `append` on
/// the source's thread, the writer asks for more on its own queue, and `lock` keeps them in step.
final class Recording: @unchecked Sendable {
  /// Where to fake a failure (see Preferences.recordingTestFailure).
  enum TestFailure: String {
    /// Creating the recording's file.
    case start
    /// Writing, a few seconds in.
    case write
    /// Finishing the movie.
    case finish
    /// Halfway through letterboxing, which happens even without a rotation.
    case letterbox
  }

  enum Outcome {
    case saved(URL)
    /// Saved as it arrived, because letterboxing failed.
    case savedWithoutLetterboxing(URL, any Error)
  }

  private static let testWriteFailureDelay = CMTime(value: 3, timescale: 1)
  /// Only a writer that's genuinely stuck (a struggling disk) falls this far behind.
  private static let maxPendingBytes = 64 * 1024 * 1024
  private static let drainCheckInterval = Duration.milliseconds(20)
  /// A writer that stops taking frames without failing would otherwise hold up saving, and quitting.
  private static let drainTimeout = Duration.seconds(30)
  private static let finishFailedMessage = "Finishing the recording failed, so it wasn't saved. Try recording again."

  private let deviceName: String
  /// Names the movie, which is only given a name once it's saved, so it can't collide.
  private let startDate = Date.now
  private let writer: AVAssetWriter
  /// The movie is written here, and only moved to the capture folder once it's finished.
  private let temporaryFolder: URL
  private let startTime: CMTime
  private let onFailure: @Sendable (any Error) -> Void
  private let testFailure = Preferences.recordingTestFailure
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.jstayton.remi.recording")
  private var input: AVAssetWriterInput?
  private var pending: [CMSampleBuffer] = []
  private var pendingBytes = 0
  private var isWaitingForKeyFrame = true
  private var lastFrameTime: CMTime?
  private var frameSizes: [CGSize] = []
  private var failure: (any Error)?

  /// `onFailure` runs on the source's thread, once, if writing fails partway through.
  init(deviceName: String, startTime: CMTime, onFailure: @escaping @Sendable (any Error) -> Void) throws {
    do {
      if testFailure == .start {
        throw RemiError(.recordingFailed, "A test failure (recordingTestFailure is start)")
      }
      // On the same volume as the capture folder, so moving the finished movie there is instant.
      temporaryFolder = try FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: CaptureFile.folder(), create: true)
      writer = try AVAssetWriter(outputURL: temporaryFolder.appending(path: "Recording.mov"), fileType: .mov)
    } catch {
      throw RemiError(.recordingFailed, "Couldn't create a file for the recording.", cause: error)
    }
    self.deviceName = deviceName
    self.startTime = startTime
    self.onFailure = onFailure
  }

  /// The first frame written is a key frame. One from before `startTime` (the last key frame
  /// before recording started) is written but trimmed, so the movie starts at `startTime`.
  func append(_ sampleBuffer: CMSampleBuffer, at time: CMTime, isKeyFrame: Bool) {
    lock.withLock {
      guard failure == nil else {
        return
      }
      if isWaitingForKeyFrame {
        guard isKeyFrame else {
          return
        }
        isWaitingForKeyFrame = false
      }
      do {
        if testFailure == .write && time >= startTime + Self.testWriteFailureDelay {
          throw RemiError(.recordingFailed, "A test failure (recordingTestFailure is write)")
        }
        if input == nil {
          try startWriting(formatHint: sampleBuffer.formatDescription, firstFrameTime: time)
        }
        guard queueFrame(try retimed(sampleBuffer, at: time), isKeyFrame: isKeyFrame) else {
          return
        }
        lastFrameTime = time
        if let dimensions = sampleBuffer.formatDescription?.dimensions {
          let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
          if !frameSizes.contains(size) {
            frameSizes.append(size)
          }
        }
        try writePending()
      } catch {
        fail(error)
      }
    }
  }

  /// Returns false if the frame was dropped. Must hold `lock`.
  private func queueFrame(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) -> Bool {
    if pendingBytes + sampleBuffer.totalSampleSize > Self.maxPendingBytes {
      // Frames after a dropped one can't be decoded, so the rest wait for the next key frame.
      Log.video.warning("The recording fell behind, so frames were dropped")
      pending.removeAll()
      pendingBytes = 0
      if !isKeyFrame {
        isWaitingForKeyFrame = true
        return false
      }
    }
    pending.append(sampleBuffer)
    pendingBytes += sampleBuffer.totalSampleSize
    return true
  }

  /// Hands queued frames to the writer for as long as it takes them. Must hold `lock`.
  private func writePending() throws {
    guard let input else {
      return
    }
    while let sampleBuffer = pending.first, input.isReadyForMoreMediaData {
      guard input.append(sampleBuffer) else {
        throw RemiError(.recordingFailed, "Failed to append a frame", cause: writer.error)
      }
      pending.removeFirst()
      pendingBytes -= sampleBuffer.totalSampleSize
    }
  }

  /// Must hold `lock`.
  private func fail(_ error: any Error) {
    let failure = RemiError(
      .recordingFailed, "Writing the recording failed, so it stopped. Check that the disk has free space.",
      cause: error)
    self.failure = failure
    pending.removeAll()
    pendingBytes = 0
    onFailure(failure)
  }

  /// Waits until the writer has taken every queued frame, writing has failed, or the timeout
  /// passes, after which the movie is finished with what was written.
  private func waitUntilDrained() async {
    let deadline = ContinuousClock.now + Self.drainTimeout
    while ContinuousClock.now < deadline && writer.status == .writing
      && lock.withLock({ !pending.isEmpty && failure == nil })
    {
      try? await Task.sleep(for: Self.drainCheckInterval)
    }
  }

  /// Ends the movie at `endTime`, so the last frame stays on screen until then, and saves it.
  /// `onLetterboxProgress` runs on a background queue, only if it's letterboxed. Cancelling
  /// skips letterboxing, so the recording is saved as it arrived.
  func finish(at endTime: CMTime, onLetterboxProgress: @escaping @Sendable (Double) -> Void) async throws -> Outcome {
    let movie: URL
    let letterboxError: (any Error)?
    do {
      (movie, letterboxError) = try await finishMovie(at: endTime, onLetterboxProgress: onLetterboxProgress)
    } catch {
      removeTemporaryFolder()
      throw error
    }
    let url = try save(movie)
    removeTemporaryFolder()
    return letterboxError.map { .savedWithoutLetterboxing(url, $0) } ?? .saved(url)
  }

  /// Returns the finished movie, and the error if letterboxing it failed.
  private func finishMovie(
    at endTime: CMTime, onLetterboxProgress: @escaping @Sendable (Double) -> Void
  ) async throws -> (URL, (any Error)?) {
    await waitUntilDrained()
    let (input, lastFrameTime, failure) = lock.withLock { (self.input, self.lastFrameTime, self.failure) }
    if let failure {
      discard()
      throw failure
    }
    guard let input, let lastFrameTime else {
      discard()
      throw RemiError(.recordingFailed, "The device didn't send any video to record.")
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: max(endTime, lastFrameTime))
    await writer.finishWriting()
    if testFailure == .finish {
      throw RemiError(
        .recordingFailed, Self.finishFailedMessage,
        cause: RemiError(.recordingFailed, "A test failure (recordingTestFailure is finish)"))
    }
    guard writer.status == .completed else {
      throw RemiError(.recordingFailed, Self.finishFailedMessage, cause: writer.error)
    }
    guard frameSizes.count > 1 || testFailure == .letterbox else {
      return (writer.outputURL, nil)
    }
    let letterboxedURL = temporaryFolder.appending(path: "Letterboxed.mov")
    do {
      try await Letterboxer(
        source: writer.outputURL, destination: letterboxedURL, canvasSize: canvasSize(),
        failsHalfway: testFailure == .letterbox, onProgress: onLetterboxProgress
      ).run()
      return (letterboxedURL, nil)
    } catch is CancellationError {
      Log.video.info("Letterboxing was skipped, so the recording is kept as is")
      return (writer.outputURL, nil)
    } catch {
      // A stretched rotation beats losing the recording, so keep the original instead.
      return (writer.outputURL, error)
    }
  }

  /// Moves the movie into the capture folder, or the Desktop if that fails. Failing both, the
  /// movie stays where it is rather than being lost.
  private func save(_ movie: URL) throws -> URL {
    var lastError: (any Error)?
    for folder in [CaptureFile.folder(), URL.desktopDirectory] {
      let url = CaptureFile.newURL(deviceName: deviceName, date: startDate, pathExtension: "mov", in: folder)
      do {
        try FileManager.default.moveItem(at: movie, to: url)
        return url
      } catch {
        lastError = error
      }
    }
    Log.video.error("Kept an unsaved recording at \(movie.path, privacy: .private)")
    throw RemiError(
      .recordingFailed, "Couldn't save the recording. It's been kept at \(movie.path).", cause: lastError)
  }

  private func removeTemporaryFolder() {
    try? FileManager.default.removeItem(at: temporaryFolder)
  }

  /// Fits every frame size, rounded up to even dimensions for the encoder.
  private func canvasSize() -> CGSize {
    let width = frameSizes.map(\.width).max() ?? 0
    let height = frameSizes.map(\.height).max() ?? 0
    return CGSize(width: (width / 2).rounded(.up) * 2, height: (height / 2).rounded(.up) * 2)
  }

  /// Must hold `lock`.
  private func startWriting(formatHint: CMFormatDescription?, firstFrameTime: CMTime) throws {
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else {
      throw RemiError(.recordingFailed, "Failed to add video to the recording")
    }
    writer.add(input)
    guard writer.startWriting() else {
      throw RemiError(.recordingFailed, "Failed to start writing the recording", cause: writer.error)
    }
    writer.startSession(atSourceTime: max(startTime, firstFrameTime))
    self.input = input
    input.requestMediaDataWhenReady(on: queue) { [self] in
      lock.withLock {
        do {
          try writePending()
        } catch {
          fail(error)
        }
      }
    }
  }

  /// Frames are built without timing, since mirroring shows each one as soon as it arrives.
  private func retimed(_ sampleBuffer: CMSampleBuffer, at time: CMTime) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var copy: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleBufferOut: &copy)
    guard status == noErr, let copy else {
      throw RemiError(.recordingFailed, "Couldn't time a video frame (OSStatus \(status))")
    }
    return copy
  }

  private func discard() {
    if writer.status == .writing {
      writer.cancelWriting()
    }
  }
}
