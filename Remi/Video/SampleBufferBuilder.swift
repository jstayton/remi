import CoreMedia

/// Turns H.264 Annex B packets into length-prefixed CMSampleBuffers. A rotation arrives
/// as new SPS/PPS, so a change in parameter sets produces new dimensions.
struct SampleBufferBuilder {
  struct Output {
    var sampleBuffer: CMSampleBuffer?
    var isKeyFrame = false
    /// Set when the parameter sets changed the video's dimensions.
    var newDimensions: CGSize?
  }

  private static let nalLengthSize = 4

  private var formatDescription: CMVideoFormatDescription?
  private var parameterSets: [[UInt8]] = []

  mutating func build(from bytes: UnsafeRawBufferPointer) throws -> Output {
    var output = Output()
    let units = Self.splitAnnexB(bytes)
    let incomingParameterSets = units.filter(Self.isParameterSet).map { Array($0) }
    let frameUnits = units.filter(Self.isFrameData)

    if !incomingParameterSets.isEmpty && incomingParameterSets != parameterSets {
      let previousDimensions = formatDescription.map(Self.dimensions)
      formatDescription = try Self.makeFormatDescription(incomingParameterSets)
      parameterSets = incomingParameterSets
      let dimensions = Self.dimensions(of: formatDescription!)
      if dimensions != previousDimensions {
        output.newDimensions = dimensions
      }
    }

    guard let formatDescription, !frameUnits.isEmpty else {
      return output
    }
    output.isKeyFrame = frameUnits.contains(where: Self.isKeyFrame)
    output.sampleBuffer = try Self.makeSampleBuffer(
      frameUnits, formatDescription: formatDescription, isKeyFrame: output.isKeyFrame)
    return output
  }

  private static func splitAnnexB(_ bytes: UnsafeRawBufferPointer) -> [UnsafeRawBufferPointer.SubSequence] {
    var units: [UnsafeRawBufferPointer.SubSequence] = []
    var unitStart: Int?
    var index = 0
    while index + 2 < bytes.count {
      guard bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 else {
        index += 1
        continue
      }
      if let unitStart {
        units.append(trimTrailingZeros(bytes[unitStart..<index]))
      }
      index += 3
      unitStart = index
    }
    if let unitStart, unitStart < bytes.count {
      units.append(bytes[unitStart..<bytes.count])
    }
    return units.filter { !$0.isEmpty }
  }

  /// The zero before a 4-byte start code belongs to the start code, not the previous unit.
  private static func trimTrailingZeros(
    _ unit: UnsafeRawBufferPointer.SubSequence
  ) -> UnsafeRawBufferPointer.SubSequence {
    var end = unit.endIndex
    while end > unit.startIndex && unit[end - 1] == 0 {
      end -= 1
    }
    return unit[unit.startIndex..<end]
  }

  private static func unitType(_ unit: UnsafeRawBufferPointer.SubSequence) -> UInt8 {
    unit[unit.startIndex] & 0x1F
  }

  /// SPS (7) and PPS (8).
  private static func isParameterSet(_ unit: UnsafeRawBufferPointer.SubSequence) -> Bool {
    [7, 8].contains(unitType(unit))
  }

  /// Slices and SEI (1...6).
  private static func isFrameData(_ unit: UnsafeRawBufferPointer.SubSequence) -> Bool {
    (1...6).contains(unitType(unit))
  }

  /// An IDR slice (5).
  private static func isKeyFrame(_ unit: UnsafeRawBufferPointer.SubSequence) -> Bool {
    unitType(unit) == 5
  }

  /// SPS before PPS, which is the order Core Media expects.
  private static func makeFormatDescription(_ parameterSets: [[UInt8]]) throws -> CMVideoFormatDescription {
    let ordered = parameterSets.sorted { ($0.first ?? 0) & 0x1F < ($1.first ?? 0) & 0x1F }
    var formatDescription: CMVideoFormatDescription?
    let status = withPointers(to: ordered) { pointers, sizes in
      CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
        parameterSetSizes: sizes, nalUnitHeaderLength: Int32(nalLengthSize), formatDescriptionOut: &formatDescription)
    }
    guard status == noErr, let formatDescription else {
      throw RemiError(.videoFormatInvalid, "Failed to read the video's parameter sets (OSStatus \(status))")
    }
    return formatDescription
  }

  private static func withPointers<Result>(
    to buffers: [[UInt8]], _ body: ([UnsafePointer<UInt8>], [Int]) -> Result
  ) -> Result {
    let contiguous = buffers.flatMap { $0 }
    return contiguous.withUnsafeBufferPointer { storage in
      var pointers: [UnsafePointer<UInt8>] = []
      var offset = 0
      for buffer in buffers {
        pointers.append(storage.baseAddress! + offset)
        offset += buffer.count
      }
      return body(pointers, buffers.map(\.count))
    }
  }

  private static func dimensions(of formatDescription: CMVideoFormatDescription) -> CGSize {
    CMVideoFormatDescriptionGetPresentationDimensions(
      formatDescription, usePixelAspectRatio: true, useCleanAperture: true)
  }

  private static func makeSampleBuffer(
    _ units: [UnsafeRawBufferPointer.SubSequence], formatDescription: CMVideoFormatDescription, isKeyFrame: Bool
  ) throws -> CMSampleBuffer {
    let length = units.reduce(0) { $0 + nalLengthSize + $1.count }
    var blockBuffer: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &blockBuffer)
    guard status == noErr, let blockBuffer else {
      throw RemiError(.videoFormatInvalid, "Failed to allocate a video frame (OSStatus \(status))")
    }
    // Each unit is written straight into the block buffer, after its 4-byte big-endian length.
    var offset = 0
    for unit in units {
      var unitLength = UInt32(unit.count).bigEndian
      try copy(&unitLength, count: nalLengthSize, into: blockBuffer, at: offset)
      try copy(
        UnsafeRawBufferPointer(rebasing: unit).baseAddress!, count: unit.count, into: blockBuffer,
        at: offset + nalLengthSize)
      offset += nalLengthSize + unit.count
    }

    var sampleBuffer: CMSampleBuffer?
    var sampleSize = length
    let createStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
      sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
    guard createStatus == noErr, let sampleBuffer else {
      throw RemiError(.videoFormatInvalid, "Failed to create a video frame (OSStatus \(createStatus))")
    }
    setAttachments(on: sampleBuffer, isKeyFrame: isKeyFrame)
    return sampleBuffer
  }

  private static func copy(
    _ source: UnsafeRawPointer, count: Int, into blockBuffer: CMBlockBuffer, at offset: Int
  ) throws {
    let status = CMBlockBufferReplaceDataBytes(
      with: source, blockBuffer: blockBuffer, offsetIntoDestination: offset, dataLength: count)
    guard status == noErr else {
      throw RemiError(.videoFormatInvalid, "Failed to copy a video frame (OSStatus \(status))")
    }
  }

  /// Mirroring is live, so every frame is shown as soon as it's decoded rather than on a timeline.
  private static func setAttachments(on sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    else {
      return
    }
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(
      dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
      Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    CFDictionarySetValue(
      dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
      Unmanaged.passUnretained(isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
  }
}
