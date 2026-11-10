import SwiftUI

/// Captures the exact saved profile and language disclosed before recognition.
struct ASRModelValidationConsent: Identifiable {
    enum Intent { case test, primary }
    let id = UUID()
    let backendID: ASRBackendID
    let intent: Intent
    let disclosure: ASRValidationDisclosure
    private let profileData: Data
    private let language: WhisperLanguage
    init?(backendID: ASRBackendID, intent: Intent, configuration: Configuration) {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let destination: String, isCloud: Bool, data: Data
        if let profile = configuration.localASRServices.first(where: { "service:" + $0.id.uuidString == backendID.rawValue }),
           let url = try? LocalASRServiceEndpoint.transcriptionURL(profile: profile), let encoded = try? encoder.encode(profile) {
            destination = url.absoluteString; data = encoded; isCloud = false
        } else if let profile = configuration.cloudASRConfig.providers.first(where: { "cloud:" + $0.id.uuidString == backendID.rawValue }),
                  let encoded = try? encoder.encode(profile.asrValidationIdentity) {
            if profile.protocolKind == .dashScopeRealtime {
                guard isValidRealtimeEndpoint(profile.baseURL) else { return nil }; destination = profile.baseURL
            } else { guard let url = try? CloudASREndpoint.transcriptionURL(profile.baseURL) else { return nil }; destination = url.absoluteString }
            data = encoded; isCloud = true
        } else { return nil }
        self.backendID = backendID; self.intent = intent; profileData = data; language = configuration.asrLanguage
        disclosure = .init(destination: destination, language: configuration.asrLanguage, isCloud: isCloud)
    }
    func matches(_ configuration: Configuration) -> Bool {
        guard let current = Self(backendID: backendID, intent: intent, configuration: configuration) else { return false }
        return current.profileData == profileData && current.language == language && current.disclosure == disclosure
    }
}

struct ASRModelDetail: View {
    let row: ASRModelCenterRow
    @ObservedObject var model: ASRModelCenterViewModel
    let config: Configuration?
    let actions: ASRModelCenterUIActions
    let edit: () -> Void
    @State private var consent: ASRModelValidationConsent?
    @State private var disclosureError: String?
    @State private var showsRelocation = false
    @State private var confirmsRemoval = false
    @State private var deletesFiles = false
    @State private var confirmsDeselection = false
    @State private var confirmsUnload = false
    @State private var unloadTarget: ASRBackendID?
    private var imported: ImportedASRModel? {
        guard let config else { return nil }
        return config.importedASRModels.first { ASRModelCenterPresentation.nativeID(for: $0, records: config.installedASRModels) == row.id }
    }
    private var record: ASRInstalledModelRecord? { config?.installedASRModels.first { $0.importedModelID == imported?.id } }
    private var service: LocalASRServiceProfile? { config?.localASRServices.first { "service:" + $0.id.uuidString == row.id.rawValue } }
    private var cloud: CloudASRProviderConfig? { config?.cloudASRConfig.providers.first { "cloud:" + $0.id.uuidString == row.id.rawValue } }
    private var destination: String? {
        if let service { return try? LocalASRServiceEndpoint.transcriptionURL(profile: service).absoluteString }
        if let cloud {
            return cloud.protocolKind == .dashScopeRealtime ? cloud.baseURL : (try? CloudASREndpoint.transcriptionURL(cloud.baseURL).absoluteString)
        }
        return nil
    }
    private var removalReason: String? {
        ASRModelRemovalGuard.reason(row: row, occupied: actions.removalReason?(row.id, false) ?? (actions.removalReason == nil ? "占用检查尚未接线，暂不能移除。" : nil))
    }
    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(row.location.label + " · " + row.status.label).foregroundStyle(Theme.accentText)
                    Text(row.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let reason = row.status.detail { Text(reason).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                Divider()
                if row.location == .native {
                    Text("原生推理离线运行。下载是独立操作；测试与选择不会自动下载模型。").foregroundStyle(.secondary)
                    if let imported {
                        field("格式", imported.engine.rawValue + " · " + imported.variant + (imported.bits.map { " · \($0)-bit" } ?? ""))
                        field("文件大小", ByteCountFormatter.string(fromByteCount: imported.sizeBytes, countStyle: .file) + "（\(imported.sizeBytes) 字节）")
                        field("模型目录", imported.directory.path, copyable: true)
                        if let tokenizer = imported.tokenizerDirectory { field("分词器目录", tokenizer.path, copyable: true) }
                    }
                    if let plan = record?.installPlan {
                        ForEach(Array(Set(plan.files.map { $0.source.repoID })).sorted(), id: \.self) { repo in
                            field("来源仓库", repo, copyable: true)
                            ForEach(Array(Set(plan.files.filter { $0.source.repoID == repo }.map(\.resolvedCommit))).sorted(), id: \.self) { commit in field("固定版本", commit, copyable: true) }
                            if let url = URL(string: "https://huggingface.co/" + repo + "/tree/" + (plan.files.first { $0.source.repoID == repo }?.resolvedCommit ?? "")) { Link("查看来源文件与许可证", destination: url) }
                        }
                    } else if let preset = ModelPreset.allPresets.first(where: { "native:preset:" + $0.id == row.id.rawValue }) { field("来源仓库", preset.repoId, copyable: true) }
                    if imported != nil && record?.installPlan == nil { Text("来源为用户导入；仓库版本与许可证未记录，请自行核对。").foregroundStyle(.secondary) }
                    Text("峰值内存未知；磁盘大小不等于内存需求。切换时旧模型与候选同时保留，加载前仍需硬件准入检查。").foregroundStyle(.secondary)
                    if let reason = model.nativeRecoveryDetail {
                        Text(reason).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if let loadedID = model.loadedNativeID {
                        Button("卸载当前原生模型以释放内存…") {
                            unloadTarget = loadedID; confirmsUnload = true
                        }.disabled(model.isBusy)
                        Text("请先结束录音并等待资源释放。卸载后可重新试用候选模型；记录与文件会保留。").foregroundStyle(.secondary)
                    }
                    if let oldID = model.unloadedNativeID {
                        let name = model.rows.first { $0.id == oldID }?.title ?? oldID.rawValue
                        Text("当前原生模型已卸载；原选择可能暂时未就绪。").foregroundStyle(.orange)
                        Button("重新加载原模型：" + name) { Task { await model.reloadUnloadedNative() } }.disabled(model.isBusy)
                    }
                    Text(record?.ownership == .managed ? "应用管理的下载；可分别移除记录或删除下载文件。" : "用户自有目录；移除记录不会删除原文件。")
                    if imported != nil && record?.ownership != .managed {
                        Button("重新定位模型目录…") {
                            guard let directory = actions.chooseDirectory?(), let stage = actions.stageRelocation,
                                  stage(row.id, directory) != nil else { return }
                            showsRelocation = true
                        }.disabled(model.isBusy || actions.stageRelocation == nil || actions.relocatePreview == nil)
                    }
                    if let validation = record?.validation { field("上次验证", validation.validatedAt.formatted() + " · \(validation.latencyMs) ms") }
                } else {
                    if let destination { ASRValidationNotice(disclosure: .init(destination: destination, language: config?.asrLanguage ?? .auto, isCloud: row.location == .cloud)) }
                    else { Text("无法确定有效测试地址；请先编辑配置。测试已禁用。").foregroundStyle(.orange) }
                    if let service {
                        field("协议", service.protocolKind.rawValue)
                        field("模型", service.protocolKind == .whisperCpp ? "由服务端决定；FlowType 不切换服务端模型。" : service.modelID ?? "未指定")
                        Text("FlowType 不安装、启动或更新第三方服务。服务自身可能联网。").foregroundStyle(.secondary)
                        DisclosureGroup("部署参考与协议版本") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(service.protocolKind == .whisperCpp ? [LocalASRServicePreset.whisperCpp] : [.mlxAudio, .whisperKit, .customOpenAICompatible], id: \.modelCenterReferenceID) { preset in
                                    if let guide = preset.officialGuide { Link(guide.label, destination: guide.url) }
                                    Text(preset.exampleBaseURL).textSelection(.enabled)
                                }
                                Text("这些是参考地址；测试始终使用上方已保存的实际目的地。")
                            }.padding(.top, 6)
                        }
                    }
                    if let cloud { field("模型", cloud.model); field("协议", cloud.protocolKind.rawValue) }
                    if let last = config?.asrServiceValidationRecords.last(where: { $0.backendID == row.id }) { field("上次验证", last.validatedAt.formatted()) }
                    Button("编辑配置…", action: edit).disabled(model.isBusy || !actions.canEdit(row.location))
                }
                if let result = model.lastTrialResult, result.backendID == row.id {
                    Divider()
                    Text("本次试识别 · \(result.latencyMs) ms").fontWeight(.medium)
                    Text(result.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("仅保留本次会话的输出；请自行判断转写质量。").foregroundStyle(.secondary)
                }
                Divider()
                if row.isPrimary || row.isFallback {
                    Button("解除主选 / 备选…") { confirmsDeselection = true }.disabled(model.isBusy)
                }
                Button("移除记录…", role: .destructive) { deletesFiles = false; confirmsRemoval = true }
                    .disabled(model.isBusy || removalReason != nil || (row.location == .native && imported == nil))
                if let removalReason { Text(removalReason).foregroundStyle(.secondary) }
                if record?.ownership == .managed {
                    let reason = ASRModelRemovalGuard.reason(row: row, occupied: actions.removalReason?(row.id, true) ?? (actions.removalReason == nil ? "占用检查尚未接线。" : nil))
                    Button("删除下载文件…", role: .destructive) { deletesFiles = true; confirmsRemoval = true }.disabled(model.isBusy || reason != nil)
                    if let reason, reason != removalReason { Text(reason).foregroundStyle(.secondary) }
                }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
        Divider()
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { trialButtons }
                VStack(alignment: .leading, spacing: 7) { trialButtons }
            }
            Text(row.location == .native ? "测试不替换选择；试用成功后才更改主选。" : "主选先试识别；备选需先测试并明确允许云端上传。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let disclosureError { Text(disclosureError).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }.padding(10)
        }
        .sheet(isPresented: $showsRelocation) {
            if let imported = actions.importedActions {
                ASRDirectoryPreview(actions: imported, save: {}, cancel: { imported.cancelInspection(); showsRelocation = false },
                    relocate: { previewID in
                        showsRelocation = false
                        Task { await actions.relocatePreview?(previewID) }
                    })
            }
        }
        .sheet(item: $consent) { captured in
            VStack(alignment: .leading, spacing: 16) {
                Text("确认试识别目的地").font(.title3)
                ASRValidationNotice(disclosure: captured.disclosure)
                HStack {
                    Button("取消") { consent = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(captured.intent == .test ? "发送内置样本并测试" : "试识别并设为主选") {
                        guard let latest = actions.configuration?(), captured.matches(latest) else {
                            consent = nil; disclosureError = "配置或识别语言已更改；请重新查看目的地并确认。"; return
                        }
                        consent = nil
                        let action = ASRModelRowAction(id: captured.backendID, perform: { id in
                            await runTrial(captured.intent, id: id)
                        })
                        Task {
                            guard let latest = actions.configuration?(), captured.matches(latest) else {
                                disclosureError = "配置或识别语言已更改；请重新查看目的地并确认。"; return
                            }
                            await action()
                        }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isBusy)
                }
            }.padding(20).frame(width: 520)
        }
        .alert("卸载当前原生模型？", isPresented: $confirmsUnload) {
            Button("取消", role: .cancel) { unloadTarget = nil }
            Button("卸载并保留文件") {
                guard let captured = unloadTarget else { return }
                unloadTarget = nil
                Task { await model.unloadNative(captured) }
            }
        } message: { Text("卸载会释放模型内存，保留原选择、模型记录与文件。原生识别将暂时未就绪；之后可试用候选模型或明确重新加载原模型。录音或捕获资源仍占用时会拒绝卸载。") }
        .alert("解除此后端的选择？", isPresented: $confirmsDeselection) {
            Button("取消", role: .cancel) {}
            Button("解除选择") { model.deselect(row.id) }
        } message: { Text("可能进入未就绪；不会自动选择另一项。进行中的录音继续保留原快照，移除前需等待真实计算结束。") }
        .alert(deletesFiles ? "删除应用管理的下载？" : "移除这条记录？", isPresented: $confirmsRemoval) {
            Button("取消", role: .cancel) {}
            Button(deletesFiles ? "删除下载" : "移除记录", role: .destructive) { invoke { await model.remove($0, deleteManagedFiles: deletesFiles) } }
        } message: { Text(deletesFiles ? "仅删除应用确认归属且未被占用的模型文件。此操作不可撤销。" : "移除记录不会删除用户自有目录；不会自动选择替代项。") }
    }
    @ViewBuilder private var trialButtons: some View {
        Button("测试识别") { requestTrial(.test) }.disabled(model.isBusy || row.status == .notInstalled || (row.location != .native && destination == nil))
        Button("试用并设为主选") { requestTrial(.primary) }.buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(model.isBusy || row.status == .notInstalled || (row.location != .native && destination == nil))
        Button("设为备选") { invoke { id in
            guard !model.isBusy else { return }
            await model.selectFallback(id)
            if model.notice == nil && model.busyNotice == nil, let actual = model.rows.first(where: { $0.isFallback }) { model.selectedID = actual.id }
        } }.disabled(model.isBusy || row.status == .notInstalled)
    }
    private func requestTrial(_ intent: ASRModelValidationConsent.Intent) {
        disclosureError = nil
        if row.location == .native {
            invoke { await runTrial(intent, id: $0) }
        } else if let latest = actions.configuration?(), let value = ASRModelValidationConsent(backendID: row.id, intent: intent, configuration: latest) {
            consent = value
        } else { disclosureError = "无法确定已保存的测试目的地，请先编辑配置。" }
    }
    private func runTrial(_ intent: ASRModelValidationConsent.Intent, id: ASRBackendID) async {
        guard !model.isBusy else { return }
        if intent == .test { await model.test(id) }
        else {
            await model.selectPrimary(id)
            if model.notice == nil && model.busyNotice == nil, let actual = model.rows.first(where: { $0.isPrimary }) { model.selectedID = actual.id }
        }
    }
    private func invoke(_ action: @escaping (ASRBackendID) async -> Void) { let target = ASRModelRowAction(id: row.id, perform: action); Task { await target() } }
    private func field(_ label: String, _ value: String, copyable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label).foregroundStyle(.secondary); if copyable { Button("复制") { actions.copy?(value) }.buttonStyle(.link).disabled(actions.copy == nil).accessibilityLabel("复制" + label) } }
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension LocalASRServicePreset {
    var modelCenterReferenceID: String { officialGuide?.label ?? "custom-compatible" }
}
