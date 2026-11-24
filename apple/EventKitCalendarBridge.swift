import EventKit
import Foundation
import CoreGraphics
#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Registers optional calendar access and reviewed event creation on Apple devices.
final class EventKitCalendarBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let store = EventKitCalendarStore()
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
      result(EventKitCalendarStore.accessStatus())
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
    case "prepareCreate":
      guard let request = CalendarCreateRequest(call.arguments) else {
        result(CalendarWriteError.invalidDraft.flutterError)
        return
      }
      Task { @MainActor in
        do {
          let review = try await store.prepareCreate(request)
          result(review.payload)
        } catch let error as CalendarWriteError {
          result(error.flutterError)
        } catch {
          result(CalendarWriteError.invalidDraft.flutterError)
        }
      }
    case "createReviewedEvent":
      guard let arguments = call.arguments as? [String: Any],
            let token = arguments["reviewToken"] as? String, !token.isEmpty,
            arguments["confirmed"] as? Bool == true else {
        result(CalendarWriteError.reviewRequired.flutterError)
        return
      }
      Task { @MainActor in
        do {
          let created = try await store.createReviewedEvent(token: token)
          result(created.payload)
        } catch let error as CalendarWriteError {
          result(error.flutterError)
        } catch {
          result(CalendarWriteError.saveFailed.flutterError)
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

private actor EventKitCalendarStore {
  private lazy var store = EKEventStore()
  private var accessRequestInProgress = false
  private var pendingCreates: [CalendarCreateReview] = []
  private var completedCreates: [CreatedCalendarEvent] = []

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

  func prepareCreate(_ request: CalendarCreateRequest) throws -> CalendarCreateReview {
    let (calendar, destination) = try writableCalendar(request.destination)
    let draft = try request.draft.resolve()
    guard Self.accessStatus() == "full" else { throw CalendarWriteError.accessRequired }
    guard calendar.allowsContentModifications else { throw CalendarWriteError.readOnly }
    let review = CalendarCreateReview(token: UUID().uuidString, destination: destination, draft: draft)
    pendingCreates.append(review)
    if pendingCreates.count > 32 { pendingCreates.removeFirst() }
    return review
  }

  func createReviewedEvent(token: String) throws -> CreatedCalendarEvent {
    if let completed = completedCreates.first(where: { $0.token == token }) {
      return completed
    }
    guard let index = pendingCreates.firstIndex(where: { $0.token == token }) else {
      throw CalendarWriteError.reviewRequired
    }
    let review = pendingCreates[index]
    let calendar: EKCalendar
    do {
      let (current, snapshot) = try writableCalendar(CalendarDestination(review.destination))
      guard snapshot == review.destination else { throw CalendarWriteError.changedDestination }
      if review.draft.usesDeviceZone && review.draft.timeZone != TimeZone.current {
        throw CalendarWriteError.changedTimeZone
      }
      calendar = current
    } catch {
      pendingCreates.remove(at: index)
      throw error
    }

    let event = EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = review.draft.title
    event.isAllDay = review.draft.allDay
    event.timeZone = review.draft.allDay ? nil : review.draft.timeZone
    event.startDate = review.draft.start
    event.endDate = review.draft.end
    event.location = review.draft.location
    event.notes = review.draft.notes
    do {
      try store.save(event, span: .thisEvent, commit: true)
    } catch {
      pendingCreates.remove(at: index)
      throw CalendarWriteError.saveFailed
    }

    let created = CreatedCalendarEvent(
      token: token,
      key: review.destination.key,
      eventID: event.eventIdentifier ?? event.calendarItemIdentifier
    )
    pendingCreates.remove(at: index)
    completedCreates.append(created)
    if completedCreates.count > 64 { completedCreates.removeFirst() }
    return created
  }

  private func writableCalendar(_ expected: CalendarDestination) throws -> (EKCalendar, CalendarSourceSnapshot) {
    guard Self.accessStatus() == "full" else { throw CalendarWriteError.accessRequired }
    guard let calendar = store.calendar(withIdentifier: expected.key.calendarID) else {
      throw CalendarWriteError.changedDestination
    }
    let snapshot = CalendarSourceSnapshot(calendar)
    guard snapshot.key == expected.key, snapshot.name == expected.name, snapshot.accountName == expected.accountName else {
      throw CalendarWriteError.changedDestination
    }
    guard snapshot.canWrite else { throw CalendarWriteError.readOnly }
    return (calendar, snapshot)
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

private struct CalendarSourceSnapshot: Equatable, Sendable {
  let key: CalendarKey
  let name: String
  let accountName: String
  let canWrite: Bool
  let color: Int64?

  init(_ calendar: EKCalendar) {
    key = CalendarKey(calendar)
    name = calendar.title
    accountName = calendar.source?.title ?? "Device"
    canWrite = EventKitCalendarStore.accessStatus() == "full" && calendar.allowsContentModifications
    color = Self.opaqueColor(calendar.cgColor)
  }

  var payload: [String: Any] {
    var value = key.payload
    value["name"] = name
    value["accountName"] = accountName
    value["canWrite"] = canWrite
    value["color"] = color
    return value
  }

  private static func opaqueColor(_ color: CGColor?) -> Int64? {
    guard let color, let rgb = CGColorSpace(name: CGColorSpace.sRGB),
          let components = color.converted(to: rgb, intent: .defaultIntent, options: nil)?.components,
          components.count >= 3, components.prefix(3).allSatisfy({ $0.isFinite }) else { return nil }
    func channel(_ value: CGFloat) -> Int64 {
      Int64((min(1, max(0, value)) * 255).rounded())
    }
    return 0xFF000000 | (channel(components[0]) << 16) | (channel(components[1]) << 8) | channel(components[2])
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

private enum CalendarWriteError: Error {
  case invalidDraft
  case accessRequired
  case changedDestination
  case readOnly
  case invalidLocalTime
  case ambiguousLocalTime
  case changedTimeZone
  case reviewRequired
  case saveFailed

  var flutterError: FlutterError {
    let code: String
    let message: String
    switch self {
    case .invalidDraft:
      code = "calendar_invalid_draft"
      message = "Choose a title, valid start, and later end."
    case .accessRequired:
      code = "calendar_access"
      message = "Full calendar access is required to choose a calendar for this event."
    case .changedDestination:
      code = "calendar_destination_changed"
      message = "The selected calendar changed. Choose a calendar and review the event again."
    case .readOnly:
      code = "calendar_read_only"
      message = "The selected calendar is read-only. Choose a writable calendar."
    case .invalidLocalTime:
      code = "calendar_time_gap"
      message = "The selected date or time does not exist in this time zone."
    case .ambiguousLocalTime:
      code = "calendar_time_ambiguous"
      message = "The selected clock time occurs twice that day. Choose an unambiguous time."
    case .changedTimeZone:
      code = "calendar_time_zone_changed"
      message = "The device time zone changed. Review the event again."
    case .reviewRequired:
      code = "calendar_review_required"
      message = "Review the proposed event and its calendar before saving."
    case .saveFailed:
      code = "calendar_save_failed"
      message = "The selected calendar could not save this event."
    }
    return FlutterError(code: code, message: message, details: nil)
  }
}

private struct CalendarDestination: Sendable {
  let key: CalendarKey
  let name: String
  let accountName: String

  init(_ source: CalendarSourceSnapshot) {
    key = source.key
    name = source.name
    accountName = source.accountName
  }

  init?(_ input: [String: Any]) {
    guard let key = CalendarKey(input), let name = input["name"] as? String,
          let account = input["accountName"] as? String else { return nil }
    self.key = key
    self.name = name
    accountName = account
  }
}

private struct CalendarCreateRequest: Sendable {
  let destination: CalendarDestination
  let draft: CalendarCreateDraft

  init?(_ arguments: Any?) {
    guard let payload = arguments as? [String: Any],
          let destinationInput = payload["destination"] as? [String: Any],
          let destination = CalendarDestination(destinationInput),
          let draftInput = payload["draft"] as? [String: Any],
          let draft = CalendarCreateDraft(draftInput) else { return nil }
    self.destination = destination
    self.draft = draft
  }
}

private struct CalendarCreateDraft: Sendable {
  private enum Window: Sendable {
    case days(CivilCalendarTime, CivilCalendarTime)
    case wallTimes(CivilCalendarTime, CivilCalendarTime)
    case instants(Date, Date)
  }

  let title: String
  let location: String?
  let notes: String?
  let timeZoneID: String?
  private let window: Window

  init?(_ input: [String: Any]) {
    guard let title = input["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let allDay = input["allDay"] as? Bool, let wallTime = input["wallTime"] as? Bool,
          !(allDay && wallTime) else { return nil }
    for key in ["location", "notes", "timeZoneId"] {
      if let value = input[key], !(value is String) { return nil }
    }
    self.title = title
    location = input["location"] as? String
    notes = input["notes"] as? String
    timeZoneID = input["timeZoneId"] as? String

    if allDay || wallTime {
      if allDay && timeZoneID != nil { return nil }
      guard let start = CivilCalendarTime(input["startDate"], includesTime: wallTime),
            let end = CivilCalendarTime(input["endDate"], includesTime: wallTime),
            start.label < end.label else { return nil }
      window = allDay ? .days(start, end) : .wallTimes(start, end)
    } else {
      guard let start = Self.instant(input["startMilliseconds"]),
            let end = Self.instant(input["endMilliseconds"]), start < end else { return nil }
      window = .instants(start, end)
    }
  }

  func resolve() throws -> ResolvedCalendarDraft {
    let zone: TimeZone
    if let timeZoneID {
      guard let named = TimeZone(identifier: timeZoneID) else { throw CalendarWriteError.invalidDraft }
      zone = named
    } else {
      zone = .current
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone

    let start: Date
    let end: Date
    let dates: (start: String, end: String)?
    let usesDeviceZone: Bool
    switch window {
    case let .days(first, last):
      start = try first.resolve(in: calendar)
      end = try last.resolve(in: calendar)
      dates = (first.label, last.label)
      usesDeviceZone = true
    case let .wallTimes(first, last):
      start = try first.resolve(in: calendar)
      end = try last.resolve(in: calendar)
      dates = nil
      usesDeviceZone = timeZoneID == nil
    case let .instants(first, last):
      start = first
      end = last
      dates = nil
      usesDeviceZone = false
    }
    guard start < end else { throw CalendarWriteError.invalidDraft }
    return ResolvedCalendarDraft(
      title: title, location: location, notes: notes, start: start, end: end,
      dates: dates, timeZone: zone, usesDeviceZone: usesDeviceZone
    )
  }

  private static func instant(_ value: Any?) -> Date? {
    guard let milliseconds = (value as? NSNumber)?.doubleValue,
          milliseconds.isFinite, milliseconds.rounded() == milliseconds,
          milliseconds >= -62135596800000, milliseconds <= 253402300799999 else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }
}

private struct CivilCalendarTime: Sendable {
  let label: String
  let year: Int
  let month: Int
  let day: Int
  let time: (hour: Int, minute: Int, second: Int)?

  init?(_ value: Any?, includesTime: Bool) {
    guard let label = value as? String else { return nil }
    let parts = label.split(separator: "T", omittingEmptySubsequences: false)
    guard parts.count == (includesTime ? 2 : 1) else { return nil }
    let date = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    guard date.count == 3, date[0].count == 4, date[1].count == 2, date[2].count == 2,
          let year = Self.number(date[0]), let month = Self.number(date[1]), let day = Self.number(date[2]),
          (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
    if includesTime {
      let fields = parts[1].split(separator: ":", omittingEmptySubsequences: false)
      guard fields.count == 3, fields.allSatisfy({ $0.count == 2 }),
            let hour = Self.number(fields[0]), let minute = Self.number(fields[1]), let second = Self.number(fields[2]),
            hour < 24, minute < 60, second < 60 else { return nil }
      time = (hour, minute, second)
    } else {
      time = nil
    }
    self.label = label
    self.year = year
    self.month = month
    self.day = day
  }

  func resolve(in calendar: Calendar) throws -> Date {
    let dayFields = DateComponents(year: year, month: month, day: day, hour: 12)
    guard let anchor = calendar.date(from: dayFields), matchesDay(anchor, in: calendar) else {
      throw CalendarWriteError.invalidLocalTime
    }
    let beginning = calendar.startOfDay(for: anchor)
    guard let time else { return beginning }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: year, month: month, day: day, hour: time.hour, minute: time.minute, second: time.second)
    guard let wall = utc.date(from: components) else { throw CalendarWriteError.invalidLocalTime }
    let offsets = Set([-2, 0, 2].map { calendar.timeZone.secondsFromGMT(for: wall.addingTimeInterval(Double($0) * 86400)) })
    let matches = offsets.map { wall.addingTimeInterval(-Double($0)) }.filter { value in
      let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
      return fields.year == year && fields.month == month && fields.day == day &&
        fields.hour == time.hour && fields.minute == time.minute && fields.second == time.second
    }
    guard let first = matches.first else {
      throw CalendarWriteError.invalidLocalTime
    }
    if matches.count > 1 {
      throw CalendarWriteError.ambiguousLocalTime
    }
    return first
  }

  private func matchesDay(_ date: Date, in calendar: Calendar) -> Bool {
    let fields = calendar.dateComponents([.year, .month, .day], from: date)
    return fields.year == year && fields.month == month && fields.day == day
  }

  private static func number(_ value: Substring) -> Int? {
    guard value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return Int(value)
  }
}

private struct ResolvedCalendarDraft: Sendable {
  let title: String
  let location: String?
  let notes: String?
  let start: Date
  let end: Date
  let dates: (start: String, end: String)?
  let timeZone: TimeZone
  let usesDeviceZone: Bool

  var allDay: Bool { dates != nil }
}

private struct CalendarCreateReview: Sendable {
  let token: String
  let destination: CalendarSourceSnapshot
  let draft: ResolvedCalendarDraft

  var payload: [String: Any] {
    var value = destination.payload
    value["reviewToken"] = token
    if let dates = draft.dates {
      value["startDate"] = dates.start
      value["endDate"] = dates.end
    } else {
      value["startMilliseconds"] = Int64((draft.start.timeIntervalSince1970 * 1000).rounded())
      value["endMilliseconds"] = Int64((draft.end.timeIntervalSince1970 * 1000).rounded())
      value["timeZoneId"] = draft.timeZone.identifier
    }
    return value
  }
}

private struct CreatedCalendarEvent: Sendable {
  let token: String
  let key: CalendarKey
  let eventID: String

  var payload: [String: Any] {
    var value = key.payload
    value["eventId"] = eventID
    return value
  }
}
