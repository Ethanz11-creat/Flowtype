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
    private let repo = StatsRepository(db: AppDatabaseProvider.shared)
    private init() { refresh() }
    func refresh() { stats = repo.buildDailyStats() }
}
