import Foundation

enum PolishMode: String, Codable, CaseIterable, Identifiable {
    case raw
    case polish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: return "原文"
        case .polish: return "润色"
        }
    }

    /// Backward-compatible decode: old records stored light/structured/formal — fold to .polish.
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = (value == PolishMode.raw.rawValue) ? .raw : .polish
    }
}

struct DictationSession: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let rawTranscript: String
    let finalText: String
    let polishMode: PolishMode
    let durationMs: UInt64?

    init(rawTranscript: String, finalText: String, polishMode: PolishMode, durationMs: UInt64?) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.polishMode = polishMode
        self.durationMs = durationMs
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var sessions: [DictationSession] = []

    private let store = PersistentStore<[DictationSession]>(filename: "history.json")
    private let maxEntries = 500
    private var saveDebounce: Task<Void, Never>?

    private init() {
        sessions = store.load() ?? []
    }

    func append(_ session: DictationSession) {
        sessions.insert(session, at: 0)
        if sessions.count > maxEntries {
            sessions = Array(sessions.prefix(maxEntries))
        }
        scheduleSave()

        // Aggregate to daily stats
        if let durationMs = session.durationMs {
            let wordCount = session.finalText.count
            DailyStatsStore.shared.recordSession(durationMs: durationMs, wordCount: wordCount)
        }
    }

    func delete(id: String) {
        sessions.removeAll { $0.id == id }
        scheduleSave()
    }

    func clear() {
        sessions.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.store.save(self.sessions)
        }
    }
}
