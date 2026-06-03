import Foundation

enum StatsRange: String, CaseIterable, Identifiable {
    case all, d30, d7
    var id: String { rawValue }
    var displayName: String { switch self { case .all: return "All"; case .d30: return "30d"; case .d7: return "7d" } }
}

struct HeatCell: Equatable {
    let dayOrdinal: Int
    let date: String        // yyyy-MM-dd
    let chars: Int
    let sessions: Int
    let level: Int          // 0...4
    let weekday: Int        // 0=Sun … 6=Sat
}

struct StatsSummary: Equatable {
    var sessions = 0
    var chars = 0
    var recordingSeconds = 0
    var timeSavedSeconds = 0
    var avgSpeedCPM = 0
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0
    var peakHour: Int?
    var hourHistogram = Array(repeating: 0, count: 24)
    var heatmap: [HeatCell] = []
    var isEmpty: Bool { sessions == 0 && chars == 0 }
}

enum StatsEngine {
    static let baselineCPM = StatsConfig.baselineCPM

    /// Local-day ordinal (days since era) of a date's local midnight — DST-safe.
    static func dayOrdinal(_ date: Date, _ cal: Calendar) -> Int {
        cal.ordinality(of: .day, in: .era, for: cal.startOfDay(for: date)) ?? 0
    }

    static func parseDate(_ s: String, _ cal: Calendar) -> Date? {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func filtered(_ stats: [DailyStats], range: StatsRange, now: Date, cal: Calendar) -> [DailyStats] {
        switch range {
        case .all: return stats
        case .d30, .d7:
            let days = range == .d30 ? 30 : 7
            let cutoff = dayOrdinal(now, cal) - (days - 1)
            return stats.filter { d in
                guard let date = parseDate(d.date, cal) else { return false }
                return dayOrdinal(date, cal) >= cutoff
            }
        }
    }

    static func level(_ chars: Int, max: Int) -> Int {
        guard chars > 0, max > 0 else { return 0 }
        let r = Double(chars) / Double(max)
        if r > 0.75 { return 4 }; if r > 0.5 { return 3 }; if r > 0.25 { return 2 }; return 1
    }

    static func longestRun(_ ordinals: Set<Int>) -> Int {
        guard !ordinals.isEmpty else { return 0 }
        var best = 1
        for o in ordinals where !ordinals.contains(o - 1) {
            var len = 1; while ordinals.contains(o + len) { len += 1 }
            best = max(best, len)
        }
        return best
    }

    static func currentRun(_ ordinals: Set<Int>, todayOrdinal: Int) -> Int {
        var start = todayOrdinal
        if !ordinals.contains(start) { start -= 1 }
        guard ordinals.contains(start) else { return 0 }
        var len = 0; while ordinals.contains(start - len) { len += 1 }
        return len
    }

    // MARK: Milestones (PRD §6) — pure

    /// Highest reached milestone day; 0 when streak < first milestone.
    static func flameTier(_ streak: Int) -> Int {
        StatsConfig.milestones.last(where: { streak >= $0 }) ?? 0
    }

    /// Next milestone strictly above streak; nil once the top milestone is reached.
    static func nextMilestone(_ streak: Int) -> Int? {
        StatsConfig.milestones.first(where: { $0 > streak })
    }

    /// Fraction [0,1] from the last reached anchor toward the next milestone.
    static func milestoneProgress(_ streak: Int) -> Double {
        guard let next = nextMilestone(streak) else { return 1 }
        let prev = flameTier(streak)
        let span = Double(next - prev)
        guard span > 0 else { return 1 }
        return min(1, max(0, Double(streak - prev) / span))
    }

    /// Active days (sessionCount>0) within the calendar month containing `now`.
    static func activeDaysInMonth(_ all: [DailyStats], now: Date, cal: Calendar) -> Int {
        let m = cal.dateComponents([.year, .month], from: now)
        return all.filter { $0.sessionCount > 0 }.filter { d in
            guard let date = parseDate(d.date, cal) else { return false }
            let dc = cal.dateComponents([.year, .month], from: date)
            return dc.year == m.year && dc.month == m.month
        }.count
    }

    /// Calendar month (1…12) in which the longest streak ends; nil when there is no streak.
    static func longestStreakEndMonth(_ all: [DailyStats], now: Date, cal: Calendar) -> Int? {
        let ordinals = Set(all.filter { $0.sessionCount > 0 }
            .compactMap { parseDate($0.date, cal).map { dayOrdinal($0, cal) } })
        guard !ordinals.isEmpty else { return nil }
        var best = 0, bestEnd = ordinals.max()!
        for o in ordinals where !ordinals.contains(o - 1) {
            var len = 1; while ordinals.contains(o + len) { len += 1 }
            if len >= best { best = len; bestEnd = o + len - 1 }
        }
        let todayOrd = dayOrdinal(now, cal)
        guard let endDate = cal.date(byAdding: .day, value: bestEnd - todayOrd, to: cal.startOfDay(for: now)) else { return nil }
        return cal.component(.month, from: endDate)
    }

    /// One cell per day across the range (today back N days), missing days → chars 0, level 0.
    /// Ordered oldest→newest. weekday 0=Sun..6=Sat for the UI's 7-row layout.
    static func denseHeatmap(_ all: [DailyStats], range: StatsRange, now: Date, cal: Calendar) -> [HeatCell] {
        let n = StatsConfig.days(for: range)
        var charsByDate: [String: Int] = [:], sessByDate: [String: Int] = [:]
        for d in all { charsByDate[d.date, default: 0] += d.totalWordCount; sessByDate[d.date, default: 0] += d.sessionCount }
        let maxChars = all.map { $0.totalWordCount }.max() ?? 0
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: now)
        var cells: [HeatCell] = []
        for offset in stride(from: n - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = f.string(from: day)
            let chars = charsByDate[key] ?? 0
            let weekday = (cal.component(.weekday, from: day) - 1)   // Calendar: 1=Sun → 0
            cells.append(HeatCell(dayOrdinal: dayOrdinal(day, cal), date: key, chars: chars,
                                  sessions: sessByDate[key] ?? 0, level: level(chars, max: maxChars), weekday: weekday))
        }
        return cells
    }

    static func summarize(_ all: [DailyStats], range: StatsRange, now: Date, cal: Calendar = .current) -> StatsSummary {
        let stats = filtered(all, range: range, now: now, cal: cal)
        var s = StatsSummary()
        s.sessions = stats.reduce(0) { $0 + $1.sessionCount }
        s.chars = stats.reduce(0) { $0 + $1.totalWordCount }
        let recMs = stats.reduce(UInt64(0)) { $0 + $1.totalRecordingMs }
        let durMs = stats.reduce(UInt64(0)) { $0 + $1.totalDurationMs }
        let denomMs = recMs > 0 ? recMs : durMs   // prefer pure recording; legacy fallback
        s.recordingSeconds = Int(denomMs / 1000)
        let minutes = Double(denomMs) / 1000.0 / 60.0
        s.avgSpeedCPM = minutes > 0 ? Int(Double(s.chars) / minutes) : 0
        s.timeSavedSeconds = max(0, Int(Double(s.chars) / Double(baselineCPM) * 60.0) - s.recordingSeconds)

        var hist = Array(repeating: 0, count: 24)
        for d in stats where d.hourHistogram.count == 24 { for h in 0..<24 { hist[h] += d.hourHistogram[h] } }
        s.hourHistogram = hist
        if let mx = hist.max(), mx > 0 { s.peakHour = hist.firstIndex(of: mx) }

        let ordinals = Set(stats.filter { $0.sessionCount > 0 }.compactMap { parseDate($0.date, cal).map { dayOrdinal($0, cal) } })
        s.activeDays = ordinals.count
        s.longestStreak = longestRun(ordinals)
        s.currentStreak = currentRun(ordinals, todayOrdinal: dayOrdinal(now, cal))

        s.heatmap = denseHeatmap(all, range: range, now: now, cal: cal)
        return s
    }
}
