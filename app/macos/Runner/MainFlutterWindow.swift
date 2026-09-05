import Cocoa
import FlutterMacOS
import macos_window_utils

/// Uses macos_window_utils' window subclass so the Dart side can turn on the
/// NSVisualEffectView sidebar material and hide the title bar while keeping the
/// traffic lights. Without this the window is an ordinary opaque NSWindow and the
/// vibrancy calls from Dart are silently no-ops.
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let windowFrame = self.frame
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = macOSWindowUtilsViewController
    self.setFrame(windowFrame, display: true)

    /* Initialize the macos_window_utils plugin */
    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    RegisterGeneratedPlugins(registry: macOSWindowUtilsViewController.flutterViewController)

    super.awakeFromNib()
  }
}
