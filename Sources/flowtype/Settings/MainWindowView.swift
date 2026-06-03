import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case overview
    case history
    case vocab
    case style
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .history:  return "历史"
        case .vocab:    return "词典"
        case .style:    return "风格"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .history:  return "clock.arrow.circlepath"
        case .vocab:    return "character.book.closed.fill"
        case .style:    return "paintbrush.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MainWindowView: View {
    @State private var selectedTab: AppTab = .overview

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.primary.opacity(0.06))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A single frosted backdrop behind BOTH columns — a custom sidebar (instead of
        // NavigationSplitView) so the sidebar shares the exact same .hudWindow frost as the
        // content, rather than NavigationSplitView's distinct .sidebar vibrancy.
        .background(FrostBackground())
        .tint(Brand.accent)
        .frame(minWidth: 780, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(AppTab.allCases) { tab in
                SidebarRow(tab: tab, selected: selectedTab == tab) {
                    selectedTab = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 36)   // clear the traffic-light buttons over the transparent titlebar
        .padding(.bottom, 12)
        .frame(width: 176)
    }

    @ViewBuilder private var detail: some View {
        switch selectedTab {
        case .overview: OverviewPage()
        case .history:  HistoryPage()
        case .vocab:    VocabPage()
        case .style:    StylePage()
        case .settings: SettingsPage()
        }
    }
}

/// A single frosted-window sidebar row: transparent over the window frost, accent-tinted when selected.
private struct SidebarRow: View {
    let tab: AppTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Brand.accent : Color.primary.opacity(0.82))
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.accent.opacity(0.14)) : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
