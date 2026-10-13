import AVFoundation

/// Renders Annex B packets from a source's own thread. Frames are held (from the last key frame
/// on) until a window attaches, and after a rotation until the window has reshaped. Frames
/// also go to a Recording, if there is one.
final class VideoSink: @unchecked Sendable {
  private struct Frame {
    let sampleBuffer: CMSampleBuffer
    let arrivalTime: CMTime
    let isKeyFrame: Bool
  }

  private static let maxBacklogCount = 600
  /// Enough for a long stretch between key frames, which is what a recording starts from.
  private static let maxRecentFramesBytes = 64 * 1024 * 1024

  private let lock = NSLock()
  private var builder = SampleBufferBuilder()
  private var renderer: AVSampleBufferVideoRenderer?
  private var dimensionsHandler: (@Sendable (CGSize) -> Void)?
  private var dimensions: CGSize?
  private var backlog: [CMSampleBuffer] = []
  private var isHoldingForRotation = false
  /// Every frame since the last key frame, so a recording can start without waiting for the next.
  private var recentFrames: [Frame] = []
  private var recentFramesBytes = 0
  private var recording: Recording?

  /// `onDimensionsChange` runs on the source's thread, first with the current dimensions if known.
  func attach(renderer: AVSampleBufferVideoRenderer, onDimensionsChange: @escaping @Sendable (CGSize) -> Void) {
    lock.withLock {
      self.renderer = renderer
      dimensionsHandler = onDimensionsChange
      if let dimensions {
        onDimensionsChange(dimensions)
      }
      for sampleBuffer in backlog {
        renderer.enqueue(sampleBuffer)
      }
      backlog.removeAll()
    }
  }

  func detach() {
    lock.withLock {
      renderer?.flush()
      renderer = nil
      dimensionsHandler = nil
    }
  }

  /// Starts sending frames to `recording`, beginning with those since the last key frame.
  func startRecording(_ recording: Recording) {
    lock.withLock {
      self.recording = recording
      for frame in recentFrames {
        recording.append(frame.sampleBuffer, at: frame.arrivalTime, isKeyFrame: frame.isKeyFrame)
      }
    }
  }

  /// Once this returns, the recording gets no more frames, so it can be finished.
  func stopRecording() -> Recording? {
    lock.withLock {
      defer { recording = nil }
      return recording
    }
  }

  func receive(_ bytes: UnsafeRawBufferPointer) {
    let arrivalTime = CMClockGetTime(CMClockGetHostTimeClock())
    lock.withLock {
      do {
        let output = try builder.build(from: bytes)
        if let newDimensions = output.newDimensions {
          // A rotation: keep the old orientation on screen while the window fades it out.
          if dimensions != nil && renderer != nil {
            isHoldingForRotation = true
          }
          dimensions = newDimensions
          dimensionsHandler?(newDimensions)
        }
        if let sampleBuffer = output.sampleBuffer {
          render(sampleBuffer, isKeyFrame: output.isKeyFrame)
          let frame = Frame(sampleBuffer: sampleBuffer, arrivalTime: arrivalTime, isKeyFrame: output.isKeyFrame)
          remember(frame)
          recording?.append(sampleBuffer, at: arrivalTime, isKeyFrame: output.isKeyFrame)
        }
      } catch {
        Log.video.error("Dropped a video packet: \(error, privacy: .public)")
      }
    }
  }

  /// Releases the frames held since a rotation, once the window has its new shape.
  func resumeAfterRotation() {
    lock.withLock {
      guard isHoldingForRotation else {
        return
      }
      isHoldingForRotation = false
      for sampleBuffer in backlog {
        renderer?.enqueue(sampleBuffer)
      }
      backlog.removeAll()
    }
  }

  private func render(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
    guard let renderer, !isHoldingForRotation else {
      hold(sampleBuffer, isKeyFrame: isKeyFrame)
      return
    }
    if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
      Log.video.warning("Renderer needs a flush: \(String(describing: renderer.error))")
      renderer.flush()
    }
    renderer.enqueue(sampleBuffer)
  }

  /// Past the size limit, the frames are dropped and a recording waits for the next key frame.
  private func remember(_ frame: Frame) {
    let size = frame.sampleBuffer.totalSampleSize
    if frame.isKeyFrame {
      recentFrames = [frame]
      recentFramesBytes = size
    } else if !recentFrames.isEmpty && recentFramesBytes + size <= Self.maxRecentFramesBytes {
      recentFrames.append(frame)
      recentFramesBytes += size
    } else {
      recentFrames.removeAll()
      recentFramesBytes = 0
    }
  }

  private func hold(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
    if isKeyFrame {
      backlog = [sampleBuffer]
    } else if !backlog.isEmpty && backlog.count < Self.maxBacklogCount {
      backlog.append(sampleBuffer)
    }
  }
}
