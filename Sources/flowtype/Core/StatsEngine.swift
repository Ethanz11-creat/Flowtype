import Foundation

enum StatsRange: String, CaseIterable, Identifiable {
    case all, d30, d7
    var id: String { rawValue }
    var displayName: String { switch self { case .all: return "All"; case .d30: return "30d"; case .d7: return "7d" } }
}

struct HeatCell: Equatable { let dayOrdinal: Int; let date: String; let chars: Int; let level: Int }

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
    static let baselineCPM = 40

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

        let maxChars = stats.map { $0.totalWordCount }.max() ?? 0
        s.heatmap = stats.compactMap { d -> HeatCell? in
            guard let date = parseDate(d.date, cal) else { return nil }
            return HeatCell(dayOrdinal: dayOrdinal(date, cal), date: d.date, chars: d.totalWordCount,
                            level: level(d.totalWordCount, max: maxChars))
        }.sorted { $0.dayOrdinal < $1.dayOrdinal }
        return s
    }
}
