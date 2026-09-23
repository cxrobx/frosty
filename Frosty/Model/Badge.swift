import Foundation

enum Badge {
    /// One badge for a group tile. Counts add up; a label that isn't a count
    /// ("!", "•") only shows as a dot when there is no count to show.
    static func combined(_ labels: [String]) -> String? {
        let present = labels.filter { !$0.isEmpty }
        guard !present.isEmpty else { return nil }
        if present.count == 1 { return present[0] }
        let total = present.compactMap { Int($0.replacingOccurrences(of: ",", with: "")) }.reduce(0, +)
        return total > 0 ? String(total) : "•"
    }
}
