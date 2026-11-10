import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Sendable {
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

/// External navigation requests also reach a window that is already showing.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var requestedTab: AppTab {
        didSet {
            guard !isUpdatingDestination else { return }
            let destination = requestedTab
            // A public legacy assignment must not bypass the editor's navigation guard.
            isUpdatingDestination = true
            requestedTab = oldValue
            isUpdatingDestination = false
            navigate(to: .tab(destination))
        }
    }
    @Published private(set) var request: NavigationRequest?
    private var isUpdatingDestination = false
    private var navigationGuard: (owner: UUID, permits: (NavigationRequest) -> Bool)?

    init(initialTab: AppTab = .overview) {
        requestedTab = initialTab
    }

    func navigate(to destination: ClientDestination) {
        navigate(NavigationRequest(id: UUID(), destination: destination))
    }

    /// Continuing a deferred request keeps its identity and exact target.
    func navigate(_ request: NavigationRequest) {
        guard navigationGuard?.permits(request) ?? true else { return }
        isUpdatingDestination = true
        if requestedTab != request.destination.tab { requestedTab = request.destination.tab }
        isUpdatingDestination = false
        self.request = request
    }

    func installNavigationGuard(owner: UUID, permits: @escaping (NavigationRequest) -> Bool) {
        navigationGuard = (owner, permits)
    }

    /// A late disappearance from an older editor cannot remove a newer editor's guard.
    func removeNavigationGuard(owner: UUID) {
        if navigationGuard?.owner == owner { navigationGuard = nil }
    }
}

struct MainWindowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private(set) var selectedTab: AppTab
    @ObservedObject private var navigation: SettingsNavigation
    private var injectedPage: ((AppTab) -> AnyView)?
    typealias SettingsPageFactory = @MainActor (SettingsNavigation, SettingsConnectionChecks) -> SettingsPage
    let modelCenter: ASRModelCenterEnvironment?
    private let connectionChecks: SettingsConnectionChecks?
    private let settingsPageFactory: SettingsPageFactory?

    init(initialTab: AppTab = .overview, navigation: SettingsNavigation? = nil, page: ((AppTab) -> AnyView)? = nil,
         connectionChecks: SettingsConnectionChecks? = nil, modelCenter: ASRModelCenterEnvironment? = nil, settingsPage: SettingsPageFactory? = nil) {
        self.modelCenter = modelCenter
        self.connectionChecks = connectionChecks
        settingsPageFactory = settingsPage
        _selectedTab = State(initialValue: navigation?.requestedTab ?? initialTab)
        injectedPage = page
        self.navigation = navigation ?? SettingsNavigation(initialTab: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .background(Theme.sidebarBackground)
            Divider()
            detail
                .environment(\.clientNavigationRequest, navigation.request)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.pageBackground)
        }
        .background(Theme.pageBackground)
        .tint(Theme.accent)
        .font(Theme.Typography.body)
        .frame(minWidth: StatsConfig.minWindowWidth, minHeight: StatsConfig.minWindowHeight)
        .onReceive(navigation.$request) { request in
            guard let request else { return }
            selectedTab = request.destination.tab
        }
        .transaction { transaction in
            if reduceMotion { transaction.disablesAnimations = true }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(AppTab.allCases.filter { $0 != .settings }) { tab in
                SidebarRow(tab: tab, selected: selectedTab == tab) {
                    navigation.navigate(to: .tab(tab))
                }
            }
            Spacer()
            Divider()
            SidebarRow(tab: .settings, selected: selectedTab == .settings) {
                navigation.navigate(to: .tab(.settings))
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.top, 36)   // clear the traffic-light buttons over the transparent titlebar
        .padding(.bottom, 12)
        .frame(width: StatsConfig.sidebarWidth)
    }

    // Used by the real tab branch and isolated composition regressions. Resolve
    // production services only when a production settings page is requested.
    func makeSettingsPage() -> SettingsPage {
        let owner = connectionChecks ?? .shared
        if let settingsPageFactory { return settingsPageFactory(navigation, owner) }
        return SettingsPage(navigation: navigation, connectionChecks: owner, modelCenter: modelCenter)
    }

    @ViewBuilder private var detail: some View {
        if let injectedPage {
            injectedPage(selectedTab)
        } else {
            switch selectedTab {
            case .overview: OverviewPage(navigation: navigation)
            case .history:  HistoryPage()
            case .vocab:    VocabPage()
            case .style:    StylePage()
            case .settings: makeSettingsPage()
            }
        }
    }
}

/// Native button focus remains visible over the solid sidebar, with a restrained selected tint.
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
