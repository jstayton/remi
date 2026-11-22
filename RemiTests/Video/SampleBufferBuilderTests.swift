import CoreMedia
import Testing

@testable import Remi

struct SampleBufferBuilderTests {
  private let frames: [H264Encoder.Frame]

  init() throws {
    frames = try H264Encoder(width: 320, height: 240).encode()
  }

  private func build(_ builder: inout SampleBufferBuilder, _ bytes: [UInt8]) throws -> SampleBufferBuilder.Output {
    try bytes.withUnsafeBytes { try builder.build(from: $0) }
  }

  /// The frame's units, each after a 4-byte big-endian length, the way Core Media expects.
  private static func lengthPrefixed(_ units: [[UInt8]]) -> [UInt8] {
    units.flatMap { unit in
      withUnsafeBytes(of: UInt32(unit.count).bigEndian, Array.init) + unit
    }
  }

  private static func attachment(_ key: CFString, of sampleBuffer: CMSampleBuffer) -> Bool? {
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
    let dictionary = (attachments as? [[CFString: Any]])?.first
    return dictionary?[key] as? Bool
  }

  @Test("Builds a key frame with the video's dimensions")
  func keyFrame() throws {
    var builder = SampleBufferBuilder()
    let output = try build(&builder, frames[0].annexB())
    let sampleBuffer = try #require(output.sampleBuffer)
    #expect(output.isKeyFrame)
    #expect(output.newDimensions == CGSize(width: 320, height: 240))
    #expect([UInt8](try #require(try sampleBuffer.dataBuffer?.dataBytes())) == Self.lengthPrefixed(frames[0].units))
  }

  @Test("Builds the frames after a key frame with no new dimensions")
  func laterFrame() throws {
    var builder = SampleBufferBuilder()
    _ = try build(&builder, frames[0].annexB())
    let output = try build(&builder, frames[1].annexB(includesParameterSets: false))
    #expect(output.sampleBuffer != nil)
    #expect(!output.isKeyFrame)
    #expect(output.newDimensions == nil)
  }

  @Test("Marks only key frames as sync frames, and shows every frame as soon as it's decoded")
  func attachments() throws {
    var builder = SampleBufferBuilder()
    let keyFrame = try #require(try build(&builder, frames[0].annexB()).sampleBuffer)
    let laterFrame = try #require(try build(&builder, frames[1].annexB(includesParameterSets: false)).sampleBuffer)
    #expect(Self.attachment(kCMSampleAttachmentKey_NotSync, of: keyFrame) == false)
    #expect(Self.attachment(kCMSampleAttachmentKey_NotSync, of: laterFrame) == true)
    #expect(Self.attachment(kCMSampleAttachmentKey_DisplayImmediately, of: keyFrame) == true)
    #expect(Self.attachment(kCMSampleAttachmentKey_DisplayImmediately, of: laterFrame) == true)
  }

  @Test("Reads 3-byte start codes too")
  func shortStartCodes() throws {
    var builder = SampleBufferBuilder()
    let output = try build(&builder, frames[0].annexB(startCode: [0, 0, 1]))
    let sampleBuffer = try #require(output.sampleBuffer)
    #expect([UInt8](try #require(try sampleBuffer.dataBuffer?.dataBytes())) == Self.lengthPrefixed(frames[0].units))
  }

  @Test("Parameter sets alone report dimensions but no frame")
  func parameterSetsOnly() throws {
    var builder = SampleBufferBuilder()
    let parameterSets = H264Encoder.Frame(parameterSets: frames[0].parameterSets, units: [], isKeyFrame: true)
    let output = try build(&builder, parameterSets.annexB())
    #expect(output.sampleBuffer == nil)
    #expect(output.newDimensions == CGSize(width: 320, height: 240))
  }

  @Test("The same parameter sets again don't report new dimensions")
  func repeatedParameterSets() throws {
    var builder = SampleBufferBuilder()
    _ = try build(&builder, frames[0].annexB())
    let output = try build(&builder, frames[0].annexB())
    #expect(output.sampleBuffer != nil)
    #expect(output.newDimensions == nil)
  }

  @Test("A rotation's new parameter sets report the new dimensions")
  func rotation() throws {
    let rotated = try H264Encoder(width: 240, height: 320).encode(frameCount: 1)
    var builder = SampleBufferBuilder()
    _ = try build(&builder, frames[0].annexB())
    let output = try build(&builder, rotated[0].annexB())
    #expect(output.sampleBuffer != nil)
    #expect(output.newDimensions == CGSize(width: 240, height: 320))
  }

  @Test("Frames before any parameter sets are dropped")
  func frameBeforeParameterSets() throws {
    var builder = SampleBufferBuilder()
    let output = try build(&builder, frames[0].annexB(includesParameterSets: false))
    #expect(output.sampleBuffer == nil)
    #expect(output.newDimensions == nil)
  }

  @Test("Bytes without a start code are ignored")
  func noStartCode() throws {
    var builder = SampleBufferBuilder()
    let output = try build(&builder, [0x65, 0x88, 0x84, 0x00])
    #expect(output.sampleBuffer == nil)
    #expect(output.newDimensions == nil)
  }

  @Test("Invalid parameter sets throw")
  func invalidParameterSets() {
    var builder = SampleBufferBuilder()
    #expect {
      try build(&builder, [0, 0, 0, 1, 0x67, 0xFF, 0xFF, 0, 0, 0, 1, 0x68, 0xFF])
    } throws: { error in
      (error as? RemiError)?.code == .videoFormatInvalid
    }
  }
}
