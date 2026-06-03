import SwiftUI

/// One clause of the fun-fact footer: optional icon, lead text, a HIGHLIGHTED value, trailing text.
/// e.g. icon="keyboard", lead="少敲约 ", value="2.4 万", trail=" 次键盘".
struct FunFactClause {
    var icon: String?      // SF Symbol; nil = no icon
    var lead: String
    var value: String      // highlighted (brighter than the grey body)
    var trail: String
}

struct FunFact {
    var clauses: [FunFactClause]
    var isEmpty: Bool { clauses.isEmpty }
}

/// Produces the fun-fact footer from the current stats summary.
///
/// HOOK (per §3c/§3d): the default is the static, deterministic rule below. A future
/// `LLMFunFactProvider` can conform to this and have the model generate a fresh metaphor each
/// day/week (e.g. "少敲 N 次键盘 ≈ 消耗 X 卡路里" / "节省时间够看 K 部电影"), cached so it's cheap.
/// Swap it in via `FunFactStore.shared.provider` — the Overview view never changes.
protocol FunFactProvider {
    func fact(for summary: StatsSummary) -> FunFact
}

/// Static, deterministic fun-fact (current behavior): char count + keystrokes + movie/coffee.
struct DefaultFunFactProvider: FunFactProvider {
    func fact(for s: StatsSummary) -> FunFact {
        guard s.chars > 0 else { return FunFact(clauses: []) }
        var clauses: [FunFactClause] = [
            FunFactClause(icon: nil, lead: "你已累计口述约 ", value: Self.thousands(s.chars), trail: " 字")
        ]
        if s.chars >= 50 {
            let keystrokes = Int(Double(s.chars) * StatsConfig.keystrokesPerChar)
            clauses.append(FunFactClause(icon: "keyboard", lead: "少敲约 ", value: Self.wan(keystrokes), trail: " 次键盘"))
        }
        if s.timeSavedSeconds >= StatsConfig.secondsPerMovie {
            let movies = s.timeSavedSeconds / StatsConfig.secondsPerMovie
            clauses.append(FunFactClause(icon: "film", lead: "节省时间够看 ", value: "\(movies)", trail: " 部电影"))
        } else if s.timeSavedSeconds >= StatsConfig.secondsPerCoffee {
            let cups = s.timeSavedSeconds / StatsConfig.secondsPerCoffee
            clauses.append(FunFactClause(icon: "cup.and.saucer", lead: "够泡 ", value: "\(cups)", trail: " 杯咖啡"))
        }
        return FunFact(clauses: clauses)
    }

    static func thousands(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func wan(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1f 万", Double(n) / 10_000.0) : thousands(n)
    }
}

/// Injection point for the fun-fact source. Replace `provider` with a future LLM-backed implementation
/// (cached daily/weekly) without touching the Overview view. Defaults to the static provider.
@MainActor
final class FunFactStore: ObservableObject {
    static let shared = FunFactStore()
    var provider: FunFactProvider = DefaultFunFactProvider()
    private init() {}
    func fact(for summary: StatsSummary) -> FunFact { provider.fact(for: summary) }
}

/// Renders a FunFact as one wrapping line: icons + grey lead/trail + brighter highlighted value,
/// clauses separated by " · " — matches the prototype footer.
struct FunFactFooter: View {
    let fact: FunFact
    private let grey = Theme.textSecondary
    private let highlight = Color(hex: 0xC9C9CF)   // prototype #C9C9CF — brighter than the grey body

    var body: some View {
        composed
            .font(.system(size: 13))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5), alignment: .top)
    }

    private var composed: Text {
        var out = Text("")
        for (i, c) in fact.clauses.enumerated() {
            if i > 0 { out = out + Text("  ·  ").foregroundColor(grey) }
            if let icon = c.icon {
                out = out + Text(Image(systemName: icon)).foregroundColor(grey) + Text(" ")
            }
            out = out + Text(c.lead).foregroundColor(grey)
                + Text(c.value).foregroundColor(highlight).fontWeight(.semibold)
                + Text(c.trail).foregroundColor(grey)
        }
        return out
    }
}
