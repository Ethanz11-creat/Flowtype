import SwiftUI

struct TrialSessionView: View {
    @ObservedObject var presenter: TrialSessionPresenter
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var monitor: ReadinessMonitor
    var configureEngine: () -> Void

    var needsEngine: Bool {
        let snapshot = monitor.snapshot
        return snapshot.localModel != .ready && snapshot.cloudASR != .ready && snapshot.appleSpeech != .ready
    }
    var triggerHint: String {
        let config = store.current
        return config.interactionMode == .tapToStart
            ? "当前触发键：\(config.triggerKey.displayName)。普通听写双击开始、单击停止；试说请使用下方按钮。"
            : "当前触发键：\(config.triggerKey.displayName)。普通听写单击开始或停止；试说请使用下方按钮。"
    }
    var transmissionDisclosure: String {
        let audio = store.current.asrRoutingPolicy == .localOnly
            ? "仅本地识别：录音不发送给云端 ASR。"
            : "按当前识别配置，录音可能发送给所选云端 ASR 服务。"
        return audio + (store.current.polishOnStop
            ? "已开启文本整理；若整理服务可用，转写文字会按当前配置发送给整理服务。" : "文本整理已关闭。")
    }
    var preparationText: String? {
        let notice = presenter.controller.preparationNotice
        if notice == SessionController.preparationSubtitle(for: .degraded(.accessibilityMissing)) {
            return "无辅助功能 · 试说结果留在这里，需要时可显式复制"
        }
        return notice
    }

    // These exact actions are also exercised with an injected actual presenter.
    func start() {
        if needsEngine {
            presenter.cancel()
            configureEngine()
        } else {
            presenter.start()
        }
    }
    func stop() { presenter.stop() }
    func cancel() { presenter.cancel() }
    func disappear() { presenter.cancel() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("试说一句").font(.system(size: 13, weight: .semibold))
            Text("试说结果仅在这里显示，不会输入到其他应用或保存到历史。需要时请点击「复制结果」。")
                .font(.caption).foregroundStyle(.secondary)
            Text(triggerHint).font(.caption).foregroundStyle(.secondary)
            Text(transmissionDisclosure).font(.caption).foregroundStyle(.secondary)
            HStack {
                if presenter.controller.isRecording {
                    Button("停止", action: stop)
                } else {
                    Button(needsEngine ? "配置识别引擎" : "开始试说", action: start)
                        .disabled(presenter.isResourceBusy || presenter.controller.isPreparing || presenter.controller.isProcessing)
                }
                Button("取消", action: cancel)
            }
            if presenter.controller.isPreparing {
                Text("正在准备录音…").font(.caption).foregroundStyle(.secondary)
            } else if presenter.controller.isProcessing {
                Text("正在识别或整理…").font(.caption).foregroundStyle(.secondary)
            }
            if needsEngine {
                Text("识别引擎尚未就绪；可返回语音识别配置并显式准备。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if monitor.snapshot.microphone == .denied {
                Text("麦克风未开启，无法录音；你仍可返回配置或稍后完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if presenter.isResourceBusy {
                Text("录音资源正在使用或收尾，请稍后再试").font(.caption).foregroundStyle(.secondary)
            }
            if let notice = preparationText {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if case .error(let message) = presenter.controller.sessionState {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let notice = presenter.terminalNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let result = presenter.result, !result.isEmpty {
                Text(result).textSelection(.enabled)
                Button("复制结果") { presenter.copyResult() }
            }
        }
        .onDisappear(perform: disappear)
    }
}
