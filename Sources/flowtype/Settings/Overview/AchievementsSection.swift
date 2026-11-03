import SwiftUI

/// Uses the selected range's main values and the existing full-data calendar captions.
struct AchievementsSection: View {
    let summary: StatsSummary
    let allStats: [DailyStats]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("成就").font(Theme.Typography.sectionTitle)
            HStack(alignment: .top, spacing: 18) {
                achievement("活跃天数", icon: "calendar", value: summary.activeDays,
                    caption: "本月共 \(StatsEngine.activeDaysInMonth(allStats, now: now, cal: .current)) 天")
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    achievement("当前连续", icon: "flame", value: summary.currentStreak,
                        caption: nextCaption, warm: true)
                    ProgressView(value: StatsEngine.milestoneProgress(summary.currentStreak))
                        .tint(Theme.warm).controlSize(.small)
                        .accessibilityLabel("下一里程碑进度")
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                achievement("最长连续", icon: "trophy", value: summary.longestStreak,
                    caption: StatsEngine.longestStreakEndMonth(allStats, now: now, cal: .current)
                        .map { "个人最佳 · \($0) 月" } ?? "个人最佳")
            }
            .fixedSize(horizontal: false, vertical: true)
            milestoneTrack
        }
    }

    private var nextCaption: String {
        if let next = StatsEngine.nextMilestone(summary.currentStreak) {
            return "还差 \(next - summary.currentStreak) 天解锁 \(next) 天里程碑"
        }
        return "已达成最高里程碑"
    }

    private func achievement(_ title: String, icon: String, value: Int, caption: String, warm: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(title).foregroundStyle(Theme.textSecondary) } icon: {
                Image(systemName: icon).foregroundStyle(Theme.warm)
            }.font(.system(size: 12))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(value)").font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(warm ? Theme.warm : Theme.textPrimary)
                Text("天").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var milestoneTrack: some View {
        HStack(spacing: 5) {
            ForEach(StatsConfig.milestones, id: \.self) { day in
                let reached = summary.currentStreak >= day
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill").font(.system(size: 15))
                        .foregroundStyle(Color(hex: StatsConfig.milestoneTierHex[day] ?? StatsConfig.milestoneStartHex))
                        .opacity(reached ? 1 : 0.5)
                    Text("\(day) 天").font(.system(size: 11))
                    Image(systemName: reached ? "checkmark" : "lock.fill").font(.system(size: 9))
                }
                .foregroundStyle(reached ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day) 天，\(reached ? "已达成" : "未解锁")")
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }
}
