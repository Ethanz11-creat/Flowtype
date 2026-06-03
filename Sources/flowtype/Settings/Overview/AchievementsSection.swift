import SwiftUI

struct AchievementsSection: View {
    let summary: StatsSummary
    @ObservedObject private var store = DailyStatsStore.shared

    private func tierColor(_ day: Int) -> Color {
        Color(hex: StatsConfig.milestoneTierHex[day] ?? StatsConfig.milestoneStartHex)
    }

    var body: some View {
        let streak = summary.currentStreak
        let flameDay = StatsEngine.flameTier(streak)
        let flameColor = flameDay == 0 ? Color(hex: StatsConfig.milestoneStartHex) : tierColor(flameDay)
        let next = StatsEngine.nextMilestone(streak)
        let monthActive = StatsEngine.activeDaysInMonth(store.stats, now: Date(), cal: .current)
        let bestMonth = StatsEngine.longestStreakEndMonth(store.stats, now: Date(), cal: .current)

        VStack(alignment: .leading, spacing: 9) {
            Text("成就").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textSecondary)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    AchievementCard {
                        Image(systemName: "calendar").font(.system(size: 16)).foregroundColor(Theme.warm)
                        bigNumber("\(summary.activeDays)")
                        label("活跃天数")
                        sub("本月共 \(monthActive) 天")
                    }
                    StreakMilestoneCard(streak: streak, flameColor: flameColor,
                                        nextDay: next, progress: StatsEngine.milestoneProgress(streak),
                                        nextColor: next.map(tierColor) ?? Theme.warm)
                    AchievementCard {
                        Image(systemName: "trophy").font(.system(size: 16)).foregroundColor(Theme.warm)
                        bigNumber("\(summary.longestStreak)")
                        label("最长连续")
                        sub(bestMonth.map { "个人最佳 · \($0) 月" } ?? "个人最佳")
                    }
                }
            }
            MilestoneTrack(streak: streak)
        }
    }

    private func bigNumber(_ s: String) -> some View {
        Text(s).font(.system(size: 27, weight: .semibold)).monospacedDigit()
            .foregroundColor(Theme.textPrimary).padding(.top, 8)
    }
    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(.top, 7)
    }
    private func sub(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundColor(Color(hex: 0x7C7C84)).padding(.top, 7)
    }
}

/// Generic warm achievement card; children are leading-aligned, card stretches to row height.
private struct AchievementCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content; Spacer(minLength: 0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 15).padding(.vertical, 14)
            .glassCard()
    }
}

/// 当前连续 card — flame (tier color, breathing) + streak, progress to next milestone, caption.
private struct StreakMilestoneCard: View {
    let streak: Int
    let flameColor: Color
    let nextDay: Int?
    let progress: Double
    let nextColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 18)).foregroundColor(flameColor)
                    .scaleEffect(pulse ? 1.10 : 1.0).opacity(pulse ? 0.82 : 1.0)
                    .shadow(color: flameColor.opacity(pulse ? 0.8 : 0.4), radius: pulse ? 7 : 3)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(streak)").font(.system(size: 27, weight: .semibold)).monospacedDigit()
                        .foregroundColor(Theme.textPrimary)
                    Text(" 天").font(.system(size: 15)).foregroundColor(Theme.textSecondary)
                }
            }
            Text("当前连续").font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(.top, 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(nextColor).frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 5).padding(.top, 11)
            HStack(spacing: 4) {
                Image(systemName: "flame.fill").font(.system(size: 11)).foregroundColor(flameColor)
                if let next = nextDay {
                    Text("还差 \(next - streak) 天解锁 \(next) 天里程碑")
                } else {
                    Text("已达成最高里程碑 🎉")
                }
            }
            .font(.system(size: 11)).foregroundColor(Color(hex: 0x7C7C84)).padding(.top, 7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 14)
        .glassCard()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// §6 milestone overview: all 7 nodes — reached = lit + check, locked = dim + lock.
private struct MilestoneTrack: View {
    let streak: Int
    private func color(_ day: Int) -> Color { Color(hex: StatsConfig.milestoneTierHex[day] ?? StatsConfig.milestoneStartHex) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatsConfig.milestones, id: \.self) { day in
                let done = streak >= day
                VStack(spacing: 5) {
                    Image(systemName: "flame.fill").font(.system(size: 16)).foregroundColor(color(day))
                    Text("\(day) 天").font(.system(size: 11))
                        .foregroundColor(done ? Color(hex: 0xD6D6DC) : Color(hex: 0x7C7C84))
                    Image(systemName: done ? "checkmark" : "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(done ? Color(hex: 0x61C554) : Color(hex: 0x4A4A50))
                }
                .frame(maxWidth: .infinity)
                .opacity(done ? 1 : 0.45)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 8)
        .glassCard()
    }
}
