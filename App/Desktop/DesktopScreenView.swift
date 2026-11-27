import AppKit
import AVFoundation

/// The Private Desktop's screen, drawn by a sample buffer display layer so that picture in picture can take it over. Frames scale to
/// fit, and the view has no size of its own.
final class DesktopScreenView: NSView {
  let displayLayer = AVSampleBufferDisplayLayer()

  // A sublayer, not the view's own layer: AppKit pins its own layer's anchor to a corner, and picture in picture lays the layer out
  // around its center, so as the view's layer the frame showed offset and cropped in the PiP window.
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    displayLayer.videoGravity = .resizeAspect
    displayLayer.frame = bounds
    layer?.addSublayer(displayLayer)
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Private Desktop screen")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("DesktopScreenView is built in code") }

  override func layout() {
    super.layout()
    guard displayLayer.superlayer === layer else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
  }

  /// Shows a JPEG frame from the agent's stream.
  func show(_ frame: Data) {
    guard let buffer = Self.sampleBuffer(frame) else { return }

    let renderer = displayLayer.sampleBufferRenderer
    if renderer.requiresFlushToResumeDecoding { renderer.flush() }
    renderer.enqueue(buffer)
  }

  /// A frame as a sample buffer the layer shows as soon as it arrives, since a live screen has no timeline.
  static func sampleBuffer(_ frame: Data) -> CMSampleBuffer? {
    guard let source = CGImageSourceCreateWithData(frame as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

    var pixels: CVPixelBuffer?
    let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &pixels) == kCVReturnSuccess, let pixels else { return nil }

    CVPixelBufferLockBaseAddress(pixels, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    CVPixelBufferUnlockBaseAddress(pixels, [])

    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
    guard let format else { return nil }

    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &buffer)
    guard let buffer, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 else { return nil }

    let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    return buffer
  }
}
