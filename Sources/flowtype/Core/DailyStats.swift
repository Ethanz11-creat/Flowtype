import Foundation

struct DailyStats: Codable, Identifiable {
    let date: String // "YYYY-MM-DD"
    var totalDurationMs: UInt64
    var totalWordCount: Int
    var sessionCount: Int

    var id: String { date }

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

    func recordSession(durationMs: UInt64, wordCount: Int) {
        let date = Self.todayString
        if let idx = stats.firstIndex(where: { $0.date == date }) {
            stats[idx].totalDurationMs += durationMs
            stats[idx].totalWordCount += wordCount
            stats[idx].sessionCount += 1
        } else {
            stats.append(DailyStats(
                date: date,
                totalDurationMs: durationMs,
                totalWordCount: wordCount,
                sessionCount: 1
            ))
        }
        // Keep last 365 days
        if stats.count > 365 {
            stats.removeFirst(stats.count - 365)
        }
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

    /// Estimated time saved vs typing at 40 WPM, in whole seconds (for StatFormatting).
    var estimatedTimeSavedSeconds: Int {
        let typingMinutes = Double(totalWordCount) / 40.0
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
