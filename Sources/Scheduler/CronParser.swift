import Foundation

/// Parses human-friendly schedule strings into next-fire timestamps.
///
/// Supported formats:
/// - `"daily 3am UTC"` — fires once per day at the given hour
/// - `"daily 2pm UTC"` — 12-hour clock with am/pm
/// - `"every 6h"` — fixed interval in hours
/// - `"every 2m"` — fixed interval in minutes (for email-check etc.)
/// - `"every 48h"` — multi-hour intervals
/// - `"weekly friday 2am UTC"` — fires once per week on a given day
/// - `"every 240h"` — large hour intervals (personality-review ~10 days)
enum CronParser {

    /// A parsed schedule that can compute next-fire times.
    enum Schedule: Sendable, Equatable {
        /// Fire every N seconds (converted from hours/minutes input).
        case interval(TimeInterval)
        /// Fire daily at a specific UTC hour (0–23).
        case dailyAt(hour: Int)
        /// Fire weekly on a specific weekday (1=Sun … 7=Sat) at a UTC hour.
        case weeklyAt(weekday: Int, hour: Int)
    }

    /// Parse a human-friendly schedule string into a `Schedule`.
    ///
    /// - Parameter input: e.g. `"daily 3am UTC"`, `"every 6h"`, `"weekly friday 2am UTC"`
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
            // "every 48h" etc. already handled above
            return nil
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

        return nil
    }

    /// Compute the next fire time at or after `after` for the given schedule.
    ///
    /// - Parameters:
    ///   - schedule: The parsed schedule.
    ///   - after: Reference date (defaults to now).
    /// - Returns: The next `Date` the schedule should fire.
    static func nextFire(for schedule: Schedule, after: Date = Date()) -> Date {
        let cal = Calendar(identifier: .gregorian)
        // All schedule math in UTC
        var utcCal = cal
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        switch schedule {
        case .interval(let seconds):
            // Simple: just add the interval from `after`
            return after.addingTimeInterval(seconds)

        case .dailyAt(let hour):
            // Find next occurrence of this UTC hour
            var components = utcCal.dateComponents([.year, .month, .day], from: after)
            components.hour = hour
            components.minute = 0
            components.second = 0
            if let candidate = utcCal.date(from: components), candidate > after {
                return candidate
            }
            // Already past today's time — advance to tomorrow
            components.day! += 1
            return utcCal.date(from: components) ?? after.addingTimeInterval(86400)

        case .weeklyAt(let weekday, let hour):
            // Find next occurrence of this weekday + hour in UTC
            var components = utcCal.dateComponents([.year, .month, .day, .weekday], from: after)
            let currentWeekday = components.weekday!
            var daysAhead = weekday - currentWeekday
            if daysAhead < 0 { daysAhead += 7 }

            // If it's the right day, check if the hour has passed
            if daysAhead == 0 {
                var todayComponents = utcCal.dateComponents([.year, .month, .day], from: after)
                todayComponents.hour = hour
                todayComponents.minute = 0
                todayComponents.second = 0
                if let candidate = utcCal.date(from: todayComponents), candidate > after {
                    return candidate
                }
                daysAhead = 7 // past time today, wait a full week
            }

            let targetDay = utcCal.date(byAdding: .day, value: daysAhead, to: after)!
            var targetComponents = utcCal.dateComponents([.year, .month, .day], from: targetDay)
            targetComponents.hour = hour
            targetComponents.minute = 0
            targetComponents.second = 0
            return utcCal.date(from: targetComponents) ?? after.addingTimeInterval(Double(daysAhead) * 86400)
        }
    }

    /// Compute the recurrence interval in seconds for advancing `scheduledAt`.
    ///
    /// For interval schedules this is trivial. For daily/weekly we return
    /// 24h or 7 days respectively.
    static func recurrenceInterval(for schedule: Schedule) -> TimeInterval {
        switch schedule {
        case .interval(let seconds): return seconds
        case .dailyAt: return 86400
        case .weeklyAt: return 604800
        }
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
