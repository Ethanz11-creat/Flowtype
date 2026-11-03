import SwiftUI

struct HeroSection: View {
    let summary: StatsSummary
    let entries: [DictionaryEntry]
    let openDictionary: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PersonalizationCard(entries: entries, openDictionary: openDictionary)
                .frame(width: 178)
                .frame(maxHeight: .infinity)
            StatGrid2x2(s: summary)
        }
        .fixedSize(horizontal: false, vertical: true)   // row height = taller child (the 2×2 grid)
    }
}

private struct PersonalizationCard: View {
    let entries: [DictionaryEntry]
    let openDictionary: () -> Void
    private var progress: Double { DictionaryPresentation.enabledRatio(entries) }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.cardBorder, lineWidth: 4)
                    .frame(width: 77, height: 77)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 77, height: 77)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
            }
            VStack(spacing: 4) {
                Text("词典启用比例").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textPrimary)
                Button("词典已启用 \(entries.filter(\.enabled).count) / \(entries.count) 条", action: openDictionary)
                    .buttonStyle(.link).font(.system(size: 11))
                    .help("查看与管理已启用词条；此比例不表示模型学习进度")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .glassCard()
    }
}

private struct StatGrid2x2: View {
    let s: StatsSummary

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatCell(icon: "hourglass", iconColor: Theme.accentBright,
                         segments: StatFormatting.duration(seconds: s.timeSavedSeconds),
                         numberColor: Theme.accentText, label: "节省时间")
                StatCell(icon: "text.alignleft", iconColor: Theme.textSecondary,
                         segments: StatFormatting.plain(StatCell.thousands(s.chars)),
                         numberColor: Theme.textPrimary, label: "口述字数")
            }
            GridRow {
                StatCell(icon: "clock", iconColor: Theme.textSecondary,
                         segments: StatFormatting.duration(seconds: s.recordingSeconds),
                         numberColor: Theme.textPrimary, label: "总口述时间")
                StatCell(icon: "bolt", iconColor: Theme.textSecondary,
                         segments: StatFormatting.speed(s.avgSpeedCPM),
                         numberColor: Theme.textPrimary, label: "平均速度")
            }
        }
    }
}

private struct StatCell: View {
    let icon: String
    let iconColor: Color
    let segments: [StatSegment]
    let numberColor: Color
    let label: String

    static func thousands(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label { Text(label) } icon: {
                Image(systemName: icon).foregroundColor(iconColor)
            }.font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            StatValueView(segments: segments, numberSize: 30, unitSize: 12, numberColor: numberColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 14)
        .glassCard()
    }
}
