import Foundation

/// The trailing age of a link row: how long ago the link was added, in the largest whole unit.
/// The CLI reports a day (`added`), so the finest step is a day: `today`, then `1d`.
public enum RowAge {
    public static func text(added: String?, now: Date, calendar: Calendar = .current) -> String? {
        guard let added else { return nil }
        let parts = added.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, added.count == 10,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "today" }
        if days < 14 { return "\(days)d" }
        if days < 60 { return "\(days / 7)w" }
        if days < 730 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }
}
