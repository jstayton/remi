import CoreMedia
import CoreVideo
import Synchronization
import VideoToolbox

/// Encodes blank frames with VideoToolbox, to give tests real H.264 at a known size.
struct H264Encoder {
  /// One encoded frame's NAL units, without start codes or length prefixes.
  struct Frame {
    let parameterSets: [[UInt8]]
    let units: [[UInt8]]
    let isKeyFrame: Bool

    /// The frame as Annex B, with its parameter sets first if `includesParameterSets`.
    func annexB(includesParameterSets: Bool = true, startCode: [UInt8] = [0, 0, 0, 1]) -> [UInt8] {
      let allUnits = (includesParameterSets ? parameterSets : []) + units
      return allUnits.flatMap { startCode + $0 }
    }
  }

  let width: Int32
  let height: Int32

  /// A key frame, followed by frames that depend on it.
  func encode(frameCount: Int = 2) throws -> [Frame] {
    var session: VTCompressionSession?
    try check(
      VTCompressionSessionCreate(
        allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session))
    guard let session else {
      throw EncoderError.failed(-1)
    }
    defer { VTCompressionSessionInvalidate(session) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

    let frames = Mutex<[Frame]>([])
    let pixelBuffer = try makePixelBuffer()
    for index in 0..<frameCount {
      let options = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
      try check(
        VTCompressionSessionEncodeFrame(
          session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
          duration: .invalid, frameProperties: options, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
          guard status == noErr, let sampleBuffer, let frame = Self.frame(from: sampleBuffer) else {
            return
          }
          frames.withLock { $0.append(frame) }
        })
    }
    try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid))
    let encoded = frames.withLock { $0 }
    guard encoded.count == frameCount else {
      throw EncoderError.missingFrames(encoded.count)
    }
    return encoded
  }

  enum EncoderError: Error {
    case failed(OSStatus)
    case missingFrames(Int)
  }

  private func check(_ status: OSStatus) throws {
    guard status == noErr else {
      throw EncoderError.failed(status)
    }
  }

  private func makePixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let status = CVPixelBufferCreate(
      nil, Int(width), Int(height), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw EncoderError.failed(status)
    }
    return pixelBuffer
  }

  private static func frame(from sampleBuffer: CMSampleBuffer) -> Frame? {
    guard let formatDescription = sampleBuffer.formatDescription, let data = try? sampleBuffer.dataBuffer?.dataBytes()
    else {
      return nil
    }
    var parameterSetCount = 0
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
      parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
    let parameterSets: [[UInt8]] = (0..<parameterSetCount).compactMap { index in
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
      return pointer.map { Array(UnsafeBufferPointer(start: $0, count: size)) }
    }

    // VideoToolbox writes each unit after a 4-byte big-endian length.
    let bytes = [UInt8](data)
    var units: [[UInt8]] = []
    var offset = 0
    while offset + 4 <= bytes.count {
      let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
      units.append(Array(bytes[offset + 4..<offset + 4 + length]))
      offset += 4 + length
    }
    let attachments = sampleBuffer.sampleAttachments.first
    let isKeyFrame = attachments?[.notSync] as? Bool != true
    return Frame(parameterSets: parameterSets, units: units, isKeyFrame: isKeyFrame)
  }
}
