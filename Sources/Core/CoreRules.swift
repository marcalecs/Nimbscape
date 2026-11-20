import Foundation

/// Small pure rules shared by the app and its tests.
public enum CoreRules {
    /// Battery percentage from IOKit capacities (`current`/`max`), rounded.
    public static func batteryPercent(current: Int, max: Int) -> Int {
        max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
    }

    /// Catalog file paths must stay inside the widget's folder.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    /// Whether the launch cleanup may delete a file in the HD downloads folder: interrupted
    /// `.part` downloads and files no library item references, but never recent files.
    public static func shouldRemoveDownloadedFile(path: String, referenced: Set<String>, modified: Date, now: Date, gracePeriod: TimeInterval) -> Bool {
        guard modified < now.addingTimeInterval(-gracePeriod) else { return false }
        return path.hasSuffix(".part") || !referenced.contains(path)
    }

    /// Days of `date`'s month, padded with nils so day 1 falls in its weekday column.
    public static func monthDays(for date: Date, calendar: Calendar) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: interval.start)
        }
    }

    /// Very short weekday names starting at the calendar's first weekday.
    public static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }
}
