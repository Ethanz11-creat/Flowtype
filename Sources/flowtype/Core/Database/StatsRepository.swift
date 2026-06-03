import Foundation
import GRDB

struct StatsRepository {
    let db: AppDatabase

    static func dayString(_ date: Date, _ cal: Calendar) -> String {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// daily_legacy(date < migrationDate) ∪ fold(session for every day NOT owned by daily_legacy) → [DailyStats].
    /// A day belongs to daily_legacy ONLY if the frozen snapshot actually has it; days the snapshot is missing
    /// (e.g. old sessions whose day the legacy daily_stats.json never recorded) are aggregated from `session`,
    /// so nothing is lost and legacy-covered days are never double-counted.
    func buildDailyStats(now: Date = Date(), cal: Calendar = .current) -> [DailyStats] {
        do {
            return try db.dbQueue.read { d -> [DailyStats] in
                let migrationDay = (try String.fetchOne(d, sql: "SELECT value FROM meta WHERE key='migrationDate'"))
                    ?? Self.dayString(now, cal)
                var byDate: [String: DailyStats] = [:]
                var legacyDays = Set<String>()
                for row in try DailyLegacyRecord.fetchAll(d) where row.date < migrationDay {
                    byDate[row.date] = row.toDailyStats()
                    legacyDays.insert(row.date)
                }
                for s in try SessionRecord.fetchAll(d) {
                    let date = Date(timeIntervalSince1970: s.startedAt)
                    let day = Self.dayString(date, cal)
                    guard !legacyDays.contains(day) else { continue }   // legacy snapshot owns this day → avoid double-count
                    let hour = cal.component(.hour, from: date)
                    var ds = byDate[day] ?? DailyStats(date: day, totalDurationMs: 0, totalWordCount: 0, sessionCount: 0)
                    ds.totalDurationMs  += UInt64(max(0, s.durationMs))
                    ds.totalRecordingMs += UInt64(max(0, s.recordingMs))
                    ds.totalWordCount   += s.charCount
                    ds.sessionCount     += 1
                    ds.byApp[s.appName ?? "未知", default: 0]  += s.charCount
                    ds.byLang[s.language ?? "未知", default: 0] += s.charCount
                    if (0..<24).contains(hour) { ds.hourHistogram[hour] += 1 }
                    byDate[day] = ds
                }
                return byDate.values.sorted { $0.date < $1.date }
            }
        } catch {
            AppLogger.log("[StatsRepository] read failed: \(error)")
            return []
        }
    }
}
