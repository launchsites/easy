import EventKit
import Foundation
#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Registers the read-only EventKit methods shared by the Apple runners.
final class EventKitCalendarBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let store = EventKitCalendarReadStore()
  private var observer: NSObjectProtocol?

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let bridge = EventKitCalendarBridge()
    let methods = FlutterMethodChannel(name: "easy/event_kit_calendar", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(bridge, channel: methods)
    let changes = FlutterEventChannel(name: "easy/event_kit_calendar/changes", binaryMessenger: messenger)
    changes.setStreamHandler(bridge)
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "accessStatus":
      result(EventKitCalendarReadStore.accessStatus())
    case "requestReadAccess":
      Task { @MainActor in
        do {
          result(try await store.requestReadAccess())
        } catch {
          result(FlutterError(code: "calendar_permission", message: "Calendar access could not be requested.", details: nil))
        }
      }
    case "calendars":
      Task { @MainActor in
        do {
          let sources = try await store.calendars()
          result(sources.map(\.payload))
        } catch {
          result(Self.accessError)
        }
      }
    case "events":
      guard let window = CalendarWindow(call.arguments) else {
        result(FlutterError(code: "calendar_window", message: "Choose a valid calendar window.", details: nil))
        return
      }
      Task { @MainActor in
        do {
          let events = try await store.events(in: window)
          result(events.map(\.payload))
        } catch {
          result(Self.accessError)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    stopObserving()
    observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
      events(nil)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopObserving()
    return nil
  }

  private func stopObserving() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  private static let accessError = FlutterError(
    code: "calendar_access",
    message: "Full calendar access is required to read calendars.",
    details: nil
  )
}

private actor EventKitCalendarReadStore {
  private lazy var store = EKEventStore()
  private var accessRequestInProgress = false

  static func accessStatus() -> String {
    let authorization = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, macOS 14.0, *) {
      if authorization == .fullAccess { return "full" }
      if authorization == .writeOnly { return "writeOnly" }
    } else if authorization == .authorized {
      return "full"
    }
    if authorization == .notDetermined { return "unknown" }
    if authorization == .denied { return "denied" }
    if authorization == .restricted { return "restricted" }
    return "unavailable"
  }

  func requestReadAccess() async throws -> String {
    let status = Self.accessStatus()
    guard status == "unknown" || status == "writeOnly", !accessRequestInProgress else { return status }
    accessRequestInProgress = true
    defer { accessRequestInProgress = false }
    let _: Bool = try await withCheckedThrowingContinuation { continuation in
      let completion: (Bool, Error?) -> Void = { granted, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: granted) }
      }
      if #available(iOS 17.0, macOS 14.0, *) {
        store.requestFullAccessToEvents(completion: completion)
      } else {
        store.requestAccess(to: .event, completion: completion)
      }
    }
    return Self.accessStatus()
  }

  func calendars() throws -> [CalendarSourceSnapshot] {
    guard Self.accessStatus() == "full" else { throw CalendarAccessError.fullAccessRequired }
    return store.calendars(for: .event).map(CalendarSourceSnapshot.init).sorted { lhs, rhs in
      let order = lhs.accountName.localizedStandardCompare(rhs.accountName)
      return order == .orderedSame
        ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        : order == .orderedAscending
    }
  }

  func events(in window: CalendarWindow) throws -> [CalendarEventSnapshot] {
    guard Self.accessStatus() == "full" else { throw CalendarAccessError.fullAccessRequired }
    let calendars = store.calendars(for: .event).filter { calendar in
      window.calendars?.contains(CalendarKey(calendar)) ?? true
    }
    guard !calendars.isEmpty else { return [] }

    let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
    return store.events(matching: predicate).compactMap { event in
      guard let start = event.startDate, let end = event.endDate,
            start < window.end, end > window.start || start >= window.start else { return nil }
      return CalendarEventSnapshot(event, start: start, end: end)
    }.sorted { lhs, rhs in
      if lhs.start != rhs.start { return lhs.start < rhs.start }
      return lhs.eventID < rhs.eventID
    }
  }
}

private enum CalendarAccessError: Error {
  case fullAccessRequired
}

private struct CalendarKey: Hashable, Sendable {
  let accountID: String
  let calendarID: String

  init(_ calendar: EKCalendar) {
    accountID = calendar.source?.sourceIdentifier ?? "device"
    calendarID = calendar.calendarIdentifier
  }

  init?(_ payload: [String: Any]) {
    guard let account = payload["accountId"] as? String, !account.isEmpty,
          let calendar = payload["calendarId"] as? String, !calendar.isEmpty else { return nil }
    accountID = account
    calendarID = calendar
  }

  var payload: [String: Any] { ["accountId": accountID, "calendarId": calendarID] }
}

private struct CalendarWindow: Sendable {
  let start: Date
  let end: Date
  let calendars: Set<CalendarKey>?

  init?(_ arguments: Any?) {
    guard let payload = arguments as? [String: Any],
          let startMilliseconds = payload["startMilliseconds"] as? NSNumber,
          let endMilliseconds = payload["endMilliseconds"] as? NSNumber else { return nil }
    let startSeconds = startMilliseconds.doubleValue / 1000
    let endSeconds = endMilliseconds.doubleValue / 1000
    guard startSeconds.isFinite, endSeconds.isFinite,
          startSeconds >= -62135596800, endSeconds <= 253402300799,
          startSeconds < endSeconds, endSeconds - startSeconds <= 367 * 86400 else { return nil }
    start = Date(timeIntervalSince1970: startSeconds)
    end = Date(timeIntervalSince1970: endSeconds)
    if let selection = payload["calendars"] {
      guard let items = selection as? [[String: Any]] else { return nil }
      let keys = items.compactMap(CalendarKey.init)
      guard keys.count == items.count else { return nil }
      calendars = Set(keys)
    } else {
      calendars = nil
    }
  }
}

private struct CalendarSourceSnapshot: Sendable {
  let key: CalendarKey
  let name: String
  let accountName: String

  init(_ calendar: EKCalendar) {
    key = CalendarKey(calendar)
    name = calendar.title
    accountName = calendar.source?.title ?? "Device"
  }

  var payload: [String: Any] {
    var value = key.payload
    value["name"] = name
    value["accountName"] = accountName
    return value
  }
}

private struct CalendarEventSnapshot: Sendable {
  let key: CalendarKey
  let eventID: String
  let recurrenceID: String?
  let title: String
  let start: Date
  let end: Date
  let allDay: Bool
  let timeZoneID: String?
  let recurring: Bool
  let location: String?
  let notes: String?

  init?(_ event: EKEvent, start: Date, end: Date) {
    guard let calendar = event.calendar, let identifier = event.eventIdentifier, !identifier.isEmpty else { return nil }
    key = CalendarKey(calendar)
    eventID = identifier
    title = event.title ?? ""
    self.start = start
    self.end = end
    allDay = event.isAllDay
    timeZoneID = event.timeZone?.identifier
    recurring = event.hasRecurrenceRules || event.isDetached || event.occurrenceDate != nil
    recurrenceID = recurring ? String(Self.milliseconds(event.occurrenceDate ?? start)) : nil
    location = event.location
    notes = event.notes
  }

  var payload: [String: Any] {
    var value = key.payload
    value["eventId"] = eventID
    value["recurrenceId"] = recurrenceID
    value["title"] = title
    value["allDay"] = allDay
    value["recurring"] = recurring
    value["timeZoneId"] = timeZoneID
    value["location"] = location
    value["notes"] = notes
    if allDay {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = .autoupdatingCurrent
      value["startDate"] = Self.civilDate(start, calendar: calendar)
      value["endDate"] = Self.civilDate(end, calendar: calendar)
    } else {
      value["startMilliseconds"] = Self.milliseconds(start)
      value["endMilliseconds"] = Self.milliseconds(end)
    }
    return value
  }

  private static func civilDate(_ date: Date, calendar: Calendar) -> String? {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }
}
