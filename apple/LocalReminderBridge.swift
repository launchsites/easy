import Foundation
import UserNotifications

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class LocalReminderBridge: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  private static let channelName = "app.launchsites.easy/local_reminders"
  private static let idPattern = "^easy-local-reminder-[a-f0-9]{64}$"
  private let center = UNUserNotificationCenter.current()

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let bridge = LocalReminderBridge()
    registrar.addMethodCallDelegate(bridge, channel: channel)
    if bridge.center.delegate == nil {
      bridge.center.delegate = bridge
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "authorization":
      authorization(result: result)
    case "requestNotifications":
      center.requestAuthorization(options: [.alert, .sound]) { _, error in
        if error != nil {
          Self.finish(result, FlutterError(
            code: "permission_failed", message: "Could not request notification permission.", details: nil
          ))
        } else {
          self.authorization(result: result)
        }
      }
    case "requestExactScheduling":
      result(nil)
    case "pending":
      center.getPendingNotificationRequests { requests in
        let rows: [[String: Any]] = requests.compactMap { request in
          guard Self.isOwned(request.identifier),
                let time = request.content.userInfo["atMilliseconds"] as? NSNumber else { return nil }
          return [
            "id": request.identifier,
            "atMilliseconds": time,
            "title": request.content.title,
            "body": request.content.body
          ]
        }
        Self.finish(result, rows)
      }
    case "schedule":
      schedule(call.arguments, result: result)
    case "cancel":
      guard let ids = call.arguments as? [String], ids.allSatisfy(Self.isOwned) else {
        result(FlutterError(code: "invalid_reminder", message: "Invalid reminder identifiers.", details: nil))
        return
      }
      center.removePendingNotificationRequests(withIdentifiers: ids)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func authorization(result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      let permission: String
      switch settings.authorizationStatus {
      case .notDetermined: permission = "notDetermined"
      case .authorized, .provisional: permission = "granted"
      default:
        #if os(iOS)
        if #available(iOS 14.0, *), settings.authorizationStatus == .ephemeral {
          permission = "granted"
        } else {
          permission = "denied"
        }
        #else
        permission = "denied"
        #endif
      }
      Self.finish(result, ["permission": permission, "exactScheduling": true])
    }
  }

  private func schedule(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let data = arguments as? [String: Any],
          let id = data["id"] as? String, Self.isOwned(id),
          let time = data["atMilliseconds"] as? NSNumber,
          let title = data["title"] as? String, !title.isEmpty, title.utf8.count <= 640,
          let body = data["body"] as? String, !body.isEmpty, body.utf8.count <= 640 else {
      result(FlutterError(code: "invalid_reminder", message: "Invalid reminder.", details: nil))
      return
    }
    let fireAt = Date(timeIntervalSince1970: time.doubleValue / 1000)
    let delay = fireAt.timeIntervalSinceNow
    guard delay > 0, delay <= 31 * 24 * 60 * 60 else {
      result(FlutterError(code: "invalid_reminder_time", message: "Choose a future reminder time.", details: nil))
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = ["atMilliseconds": time]

    // UTC components keep the chosen instant exact across DST clock changes.
    var clock = Calendar(identifier: .gregorian)
    clock.timeZone = TimeZone(secondsFromGMT: 0)!
    var date = clock.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
    date.calendar = clock
    date.timeZone = clock.timeZone
    let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: false)
    let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    center.add(request) { error in
      let issue = error == nil ? nil : FlutterError(
        code: "schedule_failed", message: "Could not schedule the local reminder.", details: nil
      )
      Self.finish(result, issue)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard Self.isOwned(notification.request.identifier) else {
      completionHandler([])
      return
    }
    if #available(iOS 14.0, macOS 11.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  private static func isOwned(_ id: String) -> Bool {
    id.range(of: idPattern, options: .regularExpression) != nil
  }

  private static func finish(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }
}
