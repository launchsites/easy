import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    EventKitCalendarBridge.register(with: flutterViewController.registrar(forPlugin: "EasyEventKitCalendar"))
    LocalReminderBridge.register(with: flutterViewController.registrar(forPlugin: "EasyLocalReminders"))

    super.awakeFromNib()
  }
}
