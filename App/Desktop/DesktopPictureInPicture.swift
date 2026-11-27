import AVKit
import AppKit

/// The Private Desktop in the system's picture in picture window.
///
/// On macOS 26 picture in picture does not scale a sample buffer display layer: it mirrors the layer's whole window at one pixel
/// per pixel, from the bottom left corner, under an empty black overlay view (Apple bug FB22411168). So the frames go to a window of
/// their own that holds only the screen, starts over the pane's screen so nothing visibly changes, and while picture in picture runs
/// is invisible and kept at the picture in picture window's size, with the overlay hidden by its class name.
@MainActor
final class DesktopPictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  private let screen = DesktopScreenView()
  private let source: NSWindow
  private var controller: AVPictureInPictureController?
  private var starting: Task<Void, Never>?
  private var panelResizes: (any NSObjectProtocol)?
  private(set) var isActive = false
  /// Wants frames: starting or running.
  private(set) var isLive = false
  /// Brings the Private Desktop back on screen when picture in picture ends with its restore button.
  var onRestore: (() -> Void)?
  /// Picture in picture started or stopped.
  var onChange: (() -> Void)?

  var isSupported: Bool { controller != nil }

  override init() {
    source = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270), styleMask: [.borderless], backing: .buffered, defer: false)
    super.init()
    source.isReleasedWhenClosed = false
    source.ignoresMouseEvents = true
    source.isExcludedFromWindowsMenu = true
    source.collectionBehavior = [.transient, .ignoresCycle]
    source.contentView = screen
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

    let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: screen.displayLayer, playbackDelegate: self))
    controller.delegate = self
    controller.requiresLinearPlayback = true
    self.controller = controller
  }

  func show(_ frame: Data) {
    if isLive { screen.show(frame) }
  }

  /// Starts with the source window over `rect`, the pane's screen in screen coordinates, once it has shown a frame.
  func start(over rect: NSRect) {
    guard let controller, !isLive else { return }

    isLive = true
    onChange?()
    source.setFrame(rect, display: false)
    source.alphaValue = 1
    source.orderFront(nil)

    starting = Task { [weak self] in
      for _ in 0..<40 {
        guard let self, isLive else { return }

        if controller.isPictureInPicturePossible { return controller.startPictureInPicture() }

        try? await Task.sleep(for: .milliseconds(50))
      }

      log.error("Picture in picture never became possible.")
      self?.end()
    }
  }

  func stop() {
    if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() } else { end() }
  }

  private func end() {
    starting?.cancel()
    panelResizes.map(NotificationCenter.default.removeObserver)
    panelResizes = nil
    isLive = false
    isActive = false
    source.orderOut(nil)
    screen.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    onChange?()
  }

  /// The system's picture in picture window.
  private var panel: NSWindow? { NSApp.windows.first { String(describing: type(of: $0)).contains("PIPPanel") } }

  /// Sizes the hidden source window to the panel's content, and hides the overlay the panel may have rebuilt.
  private func fitToPanel() {
    guard let content = panel?.contentView else { return }

    source.setContentSize(content.bounds.size)

    func hideOverlay(_ view: NSView) {
      if String(describing: type(of: view)) == "AVPictureInPictureCALayerHostView" { view.isHidden = true }
      view.subviews.forEach(hideOverlay)
    }

    hideOverlay(content)
  }

  // MARK: Delegate

  nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      isActive = true
      source.alphaValue = 0
      fitToPanel()

      if let content = panel?.contentView {
        content.postsFrameChangedNotifications = true
        panelResizes = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.fitToPanel() }
        }
      }

      // The panel builds its view tree after it starts.
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(100))
        self?.fitToPanel()
      }

      onChange?()
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated { end() }
  }

  nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
    MainActor.assumeIsolated {
      log.error("Picture in picture did not start: \(error.localizedDescription)")
      end()
    }
  }

  nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    MainActor.assumeIsolated { onRestore?() }
    completionHandler(true)
  }

  // A live screen has no timeline to scrub and no pause.
  nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

  nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }

  nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

  nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

  nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    completionHandler()
  }
}
