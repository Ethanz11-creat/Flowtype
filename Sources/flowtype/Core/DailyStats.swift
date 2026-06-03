import Foundation

struct DailyStats: Codable, Identifiable {
    let date: String // "YYYY-MM-DD" (local)
    var totalDurationMs: UInt64
    var totalWordCount: Int
    var sessionCount: Int
    var totalRecordingMs: UInt64 = 0
    var byApp: [String: Int] = [:]
    var byLang: [String: Int] = [:]
    var hourHistogram: [Int] = Array(repeating: 0, count: 24)

    var id: String { date }

    init(date: String, totalDurationMs: UInt64, totalWordCount: Int, sessionCount: Int,
         totalRecordingMs: UInt64 = 0, byApp: [String: Int] = [:],
         byLang: [String: Int] = [:], hourHistogram: [Int] = Array(repeating: 0, count: 24)) {
        self.date = date
        self.totalDurationMs = totalDurationMs
        self.totalWordCount = totalWordCount
        self.sessionCount = sessionCount
        self.totalRecordingMs = totalRecordingMs
        self.byApp = byApp
        self.byLang = byLang
        self.hourHistogram = hourHistogram
    }

    // Backward-compatible decode: new fields fall back to defaults when absent (legacy JSON).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        totalDurationMs = try c.decode(UInt64.self, forKey: .totalDurationMs)
        totalWordCount = try c.decode(Int.self, forKey: .totalWordCount)
        sessionCount = try c.decode(Int.self, forKey: .sessionCount)
        totalRecordingMs = (try? c.decodeIfPresent(UInt64.self, forKey: .totalRecordingMs)) ?? 0
        byApp = (try? c.decodeIfPresent([String: Int].self, forKey: .byApp)) ?? [:]
        byLang = (try? c.decodeIfPresent([String: Int].self, forKey: .byLang)) ?? [:]
        hourHistogram = (try? c.decodeIfPresent([Int].self, forKey: .hourHistogram)) ?? Array(repeating: 0, count: 24)
    }

    var averageSpeed: Int {
        let totalMinutes = Double(totalDurationMs) / 1000.0 / 60.0
        guard totalMinutes > 0 else { return 0 }
        return Int(Double(totalWordCount) / totalMinutes)
    }
}

@MainActor
final class DailyStatsStore: ObservableObject {
    static let shared = DailyStatsStore()

    @Published private(set) var stats: [DailyStats] = []

    private let store = PersistentStore<[DailyStats]>(filename: "daily_stats.json")
    private var saveDebounce: Task<Void, Never>?

    private init() {
        stats = store.load() ?? []
    }

    func recordSession(durationMs: UInt64, recordingMs: UInt64, charCount: Int,
                       app: String, language: String, hour: Int) {
        let date = Self.todayString
        if let idx = stats.firstIndex(where: { $0.date == date }) {
            stats[idx].totalDurationMs += durationMs
            stats[idx].totalRecordingMs += recordingMs
            stats[idx].totalWordCount += charCount
            stats[idx].sessionCount += 1
            stats[idx].byApp[app, default: 0] += charCount
            stats[idx].byLang[language, default: 0] += charCount
            if (0..<24).contains(hour) { stats[idx].hourHistogram[hour] += 1 }
        } else {
            var hist = Array(repeating: 0, count: 24)
            if (0..<24).contains(hour) { hist[hour] = 1 }
            stats.append(DailyStats(date: date, totalDurationMs: durationMs, totalWordCount: charCount,
                                    sessionCount: 1, totalRecordingMs: recordingMs,
                                    byApp: [app: charCount], byLang: [language: charCount], hourHistogram: hist))
        }
        if stats.count > 365 { stats.removeFirst(stats.count - 365) }
        scheduleSave()
    }

    var totalDurationMs: UInt64 {
        stats.reduce(0) { $0 + $1.totalDurationMs }
    }

    var totalWordCount: Int {
        stats.reduce(0) { $0 + $1.totalWordCount }
    }

    var totalSessionCount: Int {
        stats.reduce(0) { $0 + $1.sessionCount }
    }

    var overallAverageSpeed: Int {
        let totalMinutes = Double(totalDurationMs) / 1000.0 / 60.0
        guard totalMinutes > 0 else { return 0 }
        return Int(Double(totalWordCount) / totalMinutes)
    }

    /// Estimated time saved vs typing at the fixed baseline (StatsConfig.baselineCPM 字/min), whole seconds.
    var estimatedTimeSavedSeconds: Int {
        let typingMinutes = Double(totalWordCount) / Double(StatsConfig.baselineCPM)
        let speakingMinutes = Double(totalDurationMs) / 1000.0 / 60.0
        return max(0, Int((typingMinutes - speakingMinutes) * 60))
    }

    private func scheduleSave() {
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.store.save(self.stats)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var todayString: String {
        dateFormatter.string(from: Date())
    }
}
