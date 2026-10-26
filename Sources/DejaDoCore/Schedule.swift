import Foundation

/// When a task runs by itself.
public struct Schedule: Codable, Equatable {
    public enum Repeat: String, Codable, CaseIterable {
        case daily, weekdays, hourly
        public var label: String {
            switch self {
            case .daily: return "Every day"
            case .weekdays: return "Weekdays"
            case .hourly: return "Every few hours"
            }
        }
    }

    public var on: Bool
    public var repeats: Repeat
    /// For daily and weekdays: the time of day. For hourly: the minute past the hour, and the first hour of the day.
    public var hour: Int
    public var minute: Int
    /// For hourly: every this many hours, from `hour` until `untilHour`.
    public var everyHours: Int
    public var untilHour: Int
    /// What to fill each `{{variable}}` with, since nobody is there to ask.
    public var values: [String: String]
    /// The scheduled time of the last run that was started or given up on.
    public var lastSlot: Date?

    /// How late a run may start after its time, for a Mac that was asleep or busy.
    public static let grace: TimeInterval = 60 * 60

    public init(on: Bool = true, repeats: Repeat = .weekdays, hour: Int = 9, minute: Int = 0,
                everyHours: Int = 2, untilHour: Int = 18, values: [String: String] = [:], lastSlot: Date? = nil) {
        self.on = on; self.repeats = repeats; self.hour = hour; self.minute = minute
        self.everyHours = everyHours; self.untilHour = untilHour; self.values = values; self.lastSlot = lastSlot
    }

    /// Every scheduled time on the day of `date`, in order.
    public func slots(onDayOf date: Date, calendar: Calendar) -> [Date] {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)   // 1 is Sunday
        func at(_ h: Int, _ m: Int) -> Date? { calendar.date(bySettingHour: h, minute: m, second: 0, of: day) }
        switch repeats {
        case .daily:
            return at(hour, minute).map { [$0] } ?? []
        case .weekdays:
            guard (2...6).contains(weekday) else { return [] }
            return at(hour, minute).map { [$0] } ?? []
        case .hourly:
            let step = max(1, min(everyHours, 24))
            let last = max(hour, min(untilHour, 23))
            return stride(from: max(0, min(hour, 23)), through: last, by: step).compactMap { at($0, minute) }
        }
    }

    /// The first scheduled time after `date`.
    public func next(after date: Date, calendar: Calendar) -> Date? {
        guard on else { return nil }
        var day = date
        for _ in 0..<9 {
            if let s = slots(onDayOf: day, calendar: calendar).first(where: { $0 > date }) { return s }
            guard let d = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return nil }
            day = d
        }
        return nil
    }

    public enum Due: Equatable {
        case none
        /// Run now for this scheduled time.
        case run(Date)
        /// These times went by too long ago to run late; the newest is the one to remember.
        case missed([Date])
    }

    /// What to do at `now`: run the newest scheduled time that has passed since
    /// the last one, if it's within the grace period; report older ones as missed.
    /// Only ever one run, however many times went by while the Mac was asleep.
    public func due(at now: Date, calendar: Calendar, since created: Date) -> Due {
        guard on else { return .none }
        let from = lastSlot ?? created
        var passed: [Date] = []
        var day = calendar.startOfDay(for: max(from, now.addingTimeInterval(-3 * 86_400)))
        while day <= now {
            passed += slots(onDayOf: day, calendar: calendar).filter { $0 > from && $0 <= now }
            guard let d = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = d
        }
        guard let newest = passed.last else { return .none }
        if now.timeIntervalSince(newest) <= Self.grace { return .run(newest) }
        return .missed(passed)
    }

    /// One line for the task list, like "Weekdays at 9:00".
    public func summary(calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "H:mm"
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let t = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base).map { f.string(from: $0) } ?? "\(hour):\(minute)"
        switch repeats {
        case .daily: return "Every day at \(t)"
        case .weekdays: return "Weekdays at \(t)"
        case .hourly: return "Every \(everyHours == 1 ? "hour" : "\(everyHours) hours") from \(t) to \(untilHour):\(String(format: "%02d", minute))"
        }
    }

    /// Why this task can't run unattended, or nil when it can.
    public static func problem(for a: Automation, values: [String: String]) -> String? {
        let asks = a.steps.contains { step in
            if case .type(_, let ask, let secret, _) = step.kind { return ask || secret }
            return false
        }
        if asks { return "It asks for text or a password each run, and nobody will be there to answer." }
        let missing = Variables.missing(a.variableNames, in: values.filter { !$0.value.isEmpty }.map(\.key))
        if !missing.isEmpty { return "Fill in " + missing.map { "{{\($0)}}" }.joined(separator: ", ") + " first." }
        return nil
    }
}
