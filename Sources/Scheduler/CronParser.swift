import Foundation

/// Parses human-friendly schedule strings AND standard 5-field cron expressions
/// into next-fire timestamps.
///
/// Supported formats:
/// - `"0 19 * * *"` — standard 5-field cron (minute hour day-of-month month day-of-week)
/// - `"*/5 * * * *"` — cron with step values
/// - `"daily 3am UTC"` — fires once per day at the given hour
/// - `"daily 2pm UTC"` — 12-hour clock with am/pm
/// - `"every 6h"` — fixed interval in hours
/// - `"every 2m"` — fixed interval in minutes (for email-check etc.)
/// - `"every 48h"` — multi-hour intervals
/// - `"weekly friday 2am UTC"` — fires once per week on a given day
/// - `"every 240h"` — large hour intervals (personality-review ~10 days)
/// - `"1w"` — shorthand for weekly interval
enum CronParser {

    // MARK: - CronField

    /// Represents a single field in a 5-field cron expression.
    enum CronField: Sendable, Equatable {
        /// Wildcard — matches any value.
        case any
        /// A single value (e.g. `19`).
        case value(Int)
        /// A step value (e.g. `*/5` means every 5).
        case step(Int)
        /// A list of values (e.g. `1,3,5`).
        case list([Int])
        /// A range of values (e.g. `1-5`).
        case range(ClosedRange<Int>)

        /// Check if this field matches a given value.
        func matches(_ v: Int) -> Bool {
            switch self {
            case .any: return true
            case .value(let n): return v == n
            case .step(let s): return s > 0 && v % s == 0
            case .list(let vals): return vals.contains(v)
            case .range(let r): return r.contains(v)
            }
        }
    }

    // MARK: - Schedule

    /// A parsed schedule that can compute next-fire times.
    enum Schedule: Sendable, Equatable {
        /// Fire every N seconds (converted from hours/minutes input).
        case interval(TimeInterval)
        /// Fire daily at a specific UTC hour (0–23).
        case dailyAt(hour: Int)
        /// Fire weekly on a specific weekday (1=Sun … 7=Sat) at a UTC hour.
        case weeklyAt(weekday: Int, hour: Int)
        /// Standard 5-field cron expression.
        case cron(minute: CronField, hour: CronField, dayOfMonth: CronField, month: CronField, dayOfWeek: CronField)
    }

    // MARK: - Parsing

    /// Parse a schedule string into a `Schedule`.
    ///
    /// - Parameter input: e.g. `"0 19 * * *"`, `"daily 3am UTC"`, `"every 6h"`
    /// - Returns: A `Schedule` value, or `nil` if the string couldn't be parsed.
    static func parse(_ input: String) -> Schedule? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()

        // "every Nh" or "every Nm"
        if s.hasPrefix("every ") {
            let rest = String(s.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if rest.hasSuffix("h"), let n = Int(rest.dropLast()) {
                return .interval(Double(n) * 3600)
            }
            if rest.hasSuffix("m"), let n = Int(rest.dropLast()) {
                return .interval(Double(n) * 60)
            }
            return nil
        }

        // Shorthand intervals: "1w", "24h", "30m"
        if s.hasSuffix("w"), let n = Int(s.dropLast()) {
            return .interval(Double(n) * 604800)
        }
        if s.hasSuffix("h"), let n = Int(s.dropLast()) {
            return .interval(Double(n) * 3600)
        }
        if s.hasSuffix("m"), let n = Int(s.dropLast()) {
            return .interval(Double(n) * 60)
        }

        // "daily 3am UTC" or "daily 2pm UTC"
        if s.hasPrefix("daily ") {
            let rest = String(s.dropFirst(6))
                .replacingOccurrences(of: "utc", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let hour = parseHour(rest) {
                return .dailyAt(hour: hour)
            }
            return nil
        }

        // "weekly friday 2am UTC"
        if s.hasPrefix("weekly ") {
            let rest = String(s.dropFirst(7))
                .replacingOccurrences(of: "utc", with: "")
                .trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: " ").map(String.init)
            guard parts.count >= 2,
                  let weekday = parseWeekday(parts[0]),
                  let hour = parseHour(parts[1])
            else { return nil }
            return .weeklyAt(weekday: weekday, hour: hour)
        }

        // Standard 5-field cron: "0 19 * * *"
        let fields = s.split(separator: " ").map(String.init)
        if fields.count == 5 {
            guard let minute = parseCronField(fields[0], min: 0, max: 59),
                  let hour = parseCronField(fields[1], min: 0, max: 23),
                  let dom = parseCronField(fields[2], min: 1, max: 31),
                  let month = parseCronField(fields[3], min: 1, max: 12),
                  let dow = parseCronField(fields[4], min: 0, max: 7)
            else { return nil }
            return .cron(minute: minute, hour: hour, dayOfMonth: dom, month: month, dayOfWeek: dow)
        }

        return nil
    }

    // MARK: - Next Fire

    /// Compute the next fire time at or after `after` for the given schedule.
    static func nextFire(for schedule: Schedule, after: Date = Date()) -> Date {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        switch schedule {
        case .interval(let seconds):
            return after.addingTimeInterval(seconds)

        case .dailyAt(let hour):
            var components = utcCal.dateComponents([.year, .month, .day], from: after)
            components.hour = hour
            components.minute = 0
            components.second = 0
            if let candidate = utcCal.date(from: components), candidate > after {
                return candidate
            }
            components.day! += 1
            return utcCal.date(from: components) ?? after.addingTimeInterval(86400)

        case .weeklyAt(let weekday, let hour):
            let components = utcCal.dateComponents([.year, .month, .day, .weekday], from: after)
            let currentWeekday = components.weekday!
            var daysAhead = weekday - currentWeekday
            if daysAhead < 0 { daysAhead += 7 }
            if daysAhead == 0 {
                var todayComponents = utcCal.dateComponents([.year, .month, .day], from: after)
                todayComponents.hour = hour
                todayComponents.minute = 0
                todayComponents.second = 0
                if let candidate = utcCal.date(from: todayComponents), candidate > after {
                    return candidate
                }
                daysAhead = 7
            }
            let targetDay = utcCal.date(byAdding: .day, value: daysAhead, to: after)!
            var targetComponents = utcCal.dateComponents([.year, .month, .day], from: targetDay)
            targetComponents.hour = hour
            targetComponents.minute = 0
            targetComponents.second = 0
            return utcCal.date(from: targetComponents) ?? after.addingTimeInterval(Double(daysAhead) * 86400)

        case .cron(let minute, let hour, let dom, let month, let dow):
            return nextCronFire(minute: minute, hour: hour, dom: dom, month: month, dow: dow, after: after, cal: utcCal)
        }
    }

    /// Compute the recurrence interval in seconds for advancing stale jobs.
    static func recurrenceInterval(for schedule: Schedule) -> TimeInterval {
        switch schedule {
        case .interval(let seconds): return seconds
        case .dailyAt: return 86400
        case .weeklyAt: return 604800
        case .cron(_, _, _, _, _):
            // For standard cron, use 60s so loadJobs advances quickly
            // and nextFire computes the real time.
            return 60
        }
    }

    // MARK: - Standard Cron Next-Fire

    /// Walk forward from `after` to find the next minute matching all 5 cron fields.
    /// Caps at 366 days to prevent infinite loops on impossible expressions.
    private static func nextCronFire(
        minute: CronField, hour: CronField, dom: CronField,
        month: CronField, dow: CronField,
        after: Date, cal: Calendar
    ) -> Date {
        // Start from the next whole minute after `after`
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: after)
        comps.second = 0
        // Advance to next minute
        comps.minute! += 1
        if comps.minute! >= 60 {
            comps.minute = 0
            comps.hour! += 1
        }
        if comps.hour! >= 24 {
            comps.hour = 0
            comps.day! += 1
        }

        guard var candidate = cal.date(from: comps) else {
            return after.addingTimeInterval(60)
        }

        let maxIterations = 366 * 24 * 60 // 1 year of minutes
        for _ in 0..<maxIterations {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: candidate)
            guard let cMonth = c.month, let cDay = c.day,
                  let cHour = c.hour, let cMinute = c.minute,
                  let cWeekday = c.weekday else {
                break
            }

            // Calendar weekday: 1=Sun..7=Sat. Cron uses 0=Sun..6=Sat (7=Sun alias).
            let cronDow = cWeekday == 1 ? 0 : cWeekday - 1

            // Check month first — if wrong, skip to next month
            if !month.matches(cMonth) {
                // Advance to 1st of next month
                var next = DateComponents()
                next.year = c.year
                next.month = cMonth + 1
                next.day = 1
                next.hour = 0
                next.minute = 0
                next.second = 0
                if let d = cal.date(from: next) {
                    candidate = d
                    continue
                }
                break
            }

            // Check day-of-month and day-of-week
            let domMatch = dom.matches(cDay)
            let dowMatch = dow.matches(cronDow) || (cronDow == 0 && dow.matches(7))
            // Standard cron: if both dom and dow are restricted (not *), either can match.
            // If only one is restricted, it must match.
            let dayMatch: Bool
            if case .any = dom {
                dayMatch = dowMatch
            } else if case .any = dow {
                dayMatch = domMatch
            } else {
                dayMatch = domMatch || dowMatch
            }

            if !dayMatch {
                // Skip to next day
                candidate = cal.date(byAdding: .day, value: 1, to: candidate)!
                var nc = cal.dateComponents([.year, .month, .day], from: candidate)
                nc.hour = 0
                nc.minute = 0
                nc.second = 0
                candidate = cal.date(from: nc) ?? candidate
                continue
            }

            // Check hour
            if !hour.matches(cHour) {
                // Skip to next hour
                candidate = cal.date(byAdding: .hour, value: 1, to: candidate)!
                var nc = cal.dateComponents([.year, .month, .day, .hour], from: candidate)
                nc.minute = 0
                nc.second = 0
                candidate = cal.date(from: nc) ?? candidate
                continue
            }

            // Check minute
            if !minute.matches(cMinute) {
                candidate = cal.date(byAdding: .minute, value: 1, to: candidate)!
                continue
            }

            // All fields match
            return candidate
        }

        // Fallback: shouldn't happen with valid cron expressions
        return after.addingTimeInterval(3600)
    }

    // MARK: - Cron Field Parsing

    /// Parse a single cron field string into a CronField.
    /// `min`/`max` define the valid range for the field.
    private static func parseCronField(_ field: String, min: Int, max: Int) -> CronField? {
        let s = field.trimmingCharacters(in: .whitespaces)

        // Wildcard
        if s == "*" { return .any }

        // Step: */N or N/M (we only support */N for simplicity)
        if s.contains("/") {
            let parts = s.split(separator: "/").map(String.init)
            guard parts.count == 2, let step = Int(parts[1]), step > 0 else { return nil }
            if parts[0] == "*" {
                return .step(step)
            }
            // Range with step (e.g. 1-30/5) — expand to list
            if parts[0].contains("-") {
                let rangeParts = parts[0].split(separator: "-").map(String.init)
                guard rangeParts.count == 2,
                      let lo = Int(rangeParts[0]), let hi = Int(rangeParts[1]),
                      lo >= min, hi <= max else { return nil }
                var vals: [Int] = []
                var v = lo
                while v <= hi { vals.append(v); v += step }
                return .list(vals)
            }
            return nil
        }

        // List: 1,3,5
        if s.contains(",") {
            let vals = s.split(separator: ",").compactMap { Int($0) }
            guard !vals.isEmpty, vals.allSatisfy({ $0 >= min && $0 <= max }) else { return nil }
            return .list(vals)
        }

        // Range: 1-5
        if s.contains("-") {
            let parts = s.split(separator: "-").map(String.init)
            guard parts.count == 2,
                  let lo = Int(parts[0]), let hi = Int(parts[1]),
                  lo >= min, hi <= max, lo <= hi else { return nil }
            return .range(lo...hi)
        }

        // Single value
        if let n = Int(s), n >= min, n <= max {
            return .value(n)
        }

        return nil
    }

    // MARK: - Private Helpers

    /// Parse "3am", "11pm", "14" into a 0–23 hour.
    private static func parseHour(_ s: String) -> Int? {
        let cleaned = s.trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("am") {
            guard let n = Int(cleaned.dropLast(2)) else { return nil }
            return n == 12 ? 0 : n  // 12am = 0
        }
        if cleaned.hasSuffix("pm") {
            guard let n = Int(cleaned.dropLast(2)) else { return nil }
            return n == 12 ? 12 : n + 12  // 12pm = 12, 1pm = 13
        }
        // Raw number (24h format)
        return Int(cleaned)
    }

    /// Parse weekday names to Calendar weekday values (1=Sunday … 7=Saturday).
    private static func parseWeekday(_ s: String) -> Int? {
        switch s.lowercased() {
        case "sunday", "sun": return 1
        case "monday", "mon": return 2
        case "tuesday", "tue": return 3
        case "wednesday", "wed": return 4
        case "thursday", "thu": return 5
        case "friday", "fri": return 6
        case "saturday", "sat": return 7
        default: return nil
        }
    }
}
