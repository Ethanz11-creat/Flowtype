import SwiftUI

struct TrialSessionView: View {
    @ObservedObject var presenter: TrialSessionPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("试说一句").font(.headline)
            Text("试说结果仅在这里显示，不会输入到其他应用或保存到历史。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if presenter.controller.isRecording {
                    Button("停止") { presenter.stop() }
                } else {
                    Button("开始试说") { presenter.start() }
                        .disabled(presenter.isResourceBusy || presenter.controller.isPreparing || presenter.controller.isProcessing)
                }
                Button("取消") { presenter.cancel() }
            }
            if presenter.isResourceBusy {
                Text("录音资源正在使用或收尾，请稍后再试").font(.caption).foregroundStyle(.secondary)
            }
            if let notice = presenter.controller.preparationNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if case .error(let message) = presenter.controller.sessionState {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let result = presenter.result {
                Text(result).textSelection(.enabled)
                Button("复制结果") { presenter.copyResult() }
            }
        }
        .onDisappear { presenter.cancel() }
    }
}
