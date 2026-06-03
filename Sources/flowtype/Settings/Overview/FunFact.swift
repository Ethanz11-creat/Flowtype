import SwiftUI

/// One clause of the footer line: optional icon, lead text, a HIGHLIGHTED value, trailing text.
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

    /// Static, deterministic footer: char count + keystrokes + movie/coffee. A plain "scientific"
    /// computation — add more playful lines here later when we want them (no provider/LLM plumbing).
    static func make(for s: StatsSummary) -> FunFact {
        guard s.chars > 0 else { return FunFact(clauses: []) }
        var clauses: [FunFactClause] = [
            FunFactClause(icon: nil, lead: "你已累计口述约 ", value: thousands(s.chars), trail: " 字")
        ]
        if s.chars >= 50 {
            let keystrokes = Int(Double(s.chars) * StatsConfig.keystrokesPerChar)
            clauses.append(FunFactClause(icon: "keyboard", lead: "少敲约 ", value: wan(keystrokes), trail: " 次键盘"))
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

    private static func thousands(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private static func wan(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1f 万", Double(n) / 10_000.0) : thousands(n)
    }
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
