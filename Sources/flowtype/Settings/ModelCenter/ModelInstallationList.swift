import SwiftUI

@MainActor struct ModelInstallationAction {
    let jobID: UUID
    let perform: (UUID) async throws -> Void
    func callAsFunction() async throws { try await perform(jobID) }
}

enum ASRModelRemovalGuard {
    static func reason(row: ASRModelCenterRow, occupied: String?) -> String? {
        if row.isPrimary || row.isFallback { return "先解除主选或备选；解除后可能进入未就绪。结束录音并等待实际计算结束后才能移除。" }
        return occupied
    }
}

struct ModelInstallationList: View {
    let installations: [ModelInstallSnapshot]
    let actions: ASRModelCenterUIActions
    let refresh: () async -> Void
    @State private var expanded = true
    @State private var message: String?
    @State private var clearing: UUID?
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if installations.isEmpty { Text("暂无安装任务。关闭页面不会中断下载。").foregroundStyle(.secondary) }
                ForEach(installations, id: \.jobID) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(job.plan.displayName).fontWeight(.medium)
                            Spacer()
                            Text(job.state == .cancelled ? "已取消 · 保留部分文件" : ASRModelCenterPresentation.installationStatus(job).label)
                        }
                        ProgressView(value: Double(job.receivedBytes), total: Double(max(1, job.plan.totalBytes)))
                            .accessibilityLabel("下载字节进度")
                        Text("\(ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: job.plan.totalBytes, countStyle: .file)) · \(job.receivedBytes) / \(job.plan.totalBytes) 字节")
                            .monospacedDigit().foregroundStyle(.secondary)
                        if let error = job.errorCode { Text(error).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        HStack {
                            if [.queued, .downloading, .verifying].contains(job.state) {
                                Button("暂停") { run(job.jobID, actions.pause) }.disabled(actions.pause == nil)
                            } else if [.paused, .failed, .cancelled].contains(job.state) {
                                Button("继续") { run(job.jobID, actions.resume) }.disabled(actions.resume == nil)
                            }
                            if job.state != .installed {
                                Button("取消任务（保留部分文件）") { run(job.jobID, actions.cancel) }.disabled(actions.cancel == nil)
                                Button("清除部分文件…", role: .destructive) { clearing = job.jobID }
                                    .disabled(actions.clearPartial == nil || ![.paused, .failed, .cancelled].contains(job.state))
                            }
                        }.controlSize(.small)
                        if actions.clearPartial == nil && job.state != .installed {
                            Text("安全清理尚未接线；暂停、取消均保留部分文件。").foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
                if let message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).font(.system(size: 11))
        } label: { Text("安装任务 · \(installations.count)").font(Theme.Typography.sectionTitle) }
        .alert("清除该任务的部分文件？", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            Button("取消", role: .cancel) { clearing = nil }
            Button("清除部分文件", role: .destructive) { if let id = clearing { run(id, actions.clearPartial) }; clearing = nil }
        } message: { Text("仅清除已停止任务的部分下载。已安装模型和用户自有目录不受影响；继续下载需要重新获取这些字节。") }
    }
    private func run(_ id: UUID, _ perform: ((UUID) async throws -> Void)?) {
        guard let perform else { return }
        let action = ModelInstallationAction(jobID: id, perform: perform)
        Task { do { try await action(); message = nil } catch { message = error.localizedDescription }; await refresh() }
    }
}
