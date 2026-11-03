import SwiftUI
import Combine

enum OnboardingStep: Int, CaseIterable {
    case introduction, engine, permissions, trial

    var title: String {
        switch self {
        case .introduction: "了解用途"
        case .engine: "准备识别引擎"
        case .permissions: "按需授权"
        case .trial: "试说一句"
        }
    }
}

/// Navigation has no preparation authority. Finishing only invokes the supplied callback.
@MainActor
final class OnboardingFlow: ObservableObject {
    @Published private(set) var step: OnboardingStep = .introduction
    let trial: TrialSessionPresenter
    let navigation: SettingsNavigation
    private var navigationObservation: AnyCancellable?
    private let onFinish: () -> Void
    private var finished = false

    init(trial: TrialSessionPresenter, navigation: SettingsNavigation,
         onNavigate: @escaping (ClientDestination) -> Void, onFinish: @escaping () -> Void) {
        self.trial = trial
        self.navigation = navigation
        self.onFinish = onFinish
        navigationObservation = navigation.$request.compactMap { $0 }.sink { [weak self] request in
            guard let self, !self.finished else { return }
            self.trial.cancel()
            onNavigate(request.destination)
        }
    }

    func advance() {
        guard !finished, let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        move(to: next)
    }
    func back() {
        guard !finished, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        move(to: previous)
    }
    func configureEngine() { guard !finished else { return }; move(to: .engine) }
    private func move(to next: OnboardingStep) {
        if step == .trial && next != .trial { trial.cancel() }
        step = next
    }
    func close() { trial.cancel() }
    func finish() {
        guard !finished else { return }
        finished = true
        close()
        onFinish()
    }
}

/// Reuses the settings components with one stable owner for checks and trial state.
struct OnboardingView: View {
    @StateObject var flow: OnboardingFlow
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var monitor: ReadinessMonitor
    @ObservedObject var modelState: QwenModelState
    @ObservedObject var downloader: ModelDownloader
    @StateObject var importedActions: ImportedASRModelActions
    @StateObject var checks: CloudASRConnectionCheck
    @StateObject var draftChecks: CloudASRConnectionCheck
    @ObservedObject var navigation: SettingsNavigation

    init(flow: OnboardingFlow, store: ConfigurationStore, monitor: ReadinessMonitor,
         modelState: QwenModelState, downloader: ModelDownloader,
         importedActions: ImportedASRModelActions, checks: CloudASRConnectionCheck,
         draftChecks: CloudASRConnectionCheck) {
        _flow = StateObject(wrappedValue: flow)
        self.store = store
        self.monitor = monitor
        self.modelState = modelState
        self.downloader = downloader
        _importedActions = StateObject(wrappedValue: importedActions)
        _checks = StateObject(wrappedValue: checks)
        _draftChecks = StateObject(wrappedValue: draftChecks)
        self.navigation = flow.navigation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Text("\(step.rawValue + 1). \(step.title)")
                        .font(.system(size: 12, weight: flow.step == step ? .semibold : .regular))
                        .foregroundStyle(flow.step == step ? Color.primary : Color.secondary)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(flow.step.title).font(Theme.Typography.pageTitle)
                    switch flow.step {
                    case .introduction:
                        Text("FlowType 将语音转成文字，供你在 macOS 应用中使用。先选择识别方式，再按需授权和试说；这些步骤都可以返回或稍后完成。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("浏览和完成设置不会开始录音、下载模型或请求权限。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    case .engine:
                        ASRSettingsContent(store: store, monitor: monitor, modelState: modelState,
                            downloader: downloader, importedActions: importedActions, navigation: navigation,
                            checks: checks, draftChecks: draftChecks)
                    case .permissions:
                        PermissionSettingsContent(store: store, monitor: monitor, navigation: navigation)
                    case .trial:
                        TrialSessionView(presenter: flow.trial, store: store, monitor: monitor,
                                         configureEngine: flow.configureEngine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if flow.step != .introduction { Button("返回", action: flow.back) }
                Button("稍后完成", action: flow.finish)
                Spacer()
                if flow.step == .trial {
                    Button("完成设置", action: flow.finish).buttonStyle(.borderedProminent)
                } else {
                    Button(flow.step == .permissions ? "继续试说（可跳过授权）" : "继续", action: flow.advance)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
        .onChange(of: store.current.cloudASRConfig) { old, new in
            checks.synchronize(old: old, new: new)
            draftChecks.synchronize(old: old, new: new)
        }
        .onAppear { monitor.refresh() }
        .onDisappear { flow.close() }
    }
}
