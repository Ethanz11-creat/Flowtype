import SwiftUI
import AppKit

/// Application composition supplies effects; a bare host fails closed and owns no service.
@MainActor struct ASRModelCenterUIActions {
    var configuration: (() -> Configuration)?
    var importedActions: ImportedASRModelActions?
    var hfSession: HFModelInstallSession?
    var discovery: ASRModelDiscoveryClient?
    var draftChecks: CloudASRConnectionCheck?
    var navigation: SettingsNavigation?
    var chooseDirectory: (() -> URL?)?
    var persistImported: ((Configuration) throws -> Void)?
    var saveLocal: ((LocalASRServiceDraft) throws -> Void)?
    var saveCloud: ((ASRProviderDraft) throws -> Void)?
    var hasCredential: ((ASRBackendID) -> Bool)?
    var credential: ((ASRBackendID) throws -> String?)?
    var saveHFToken: ((String) throws -> Void)?
    var copy: ((String) -> Void)?
    /// Must include captured usage, native drain/live recording and ownership. false = record only.
    var removalReason: ((ASRBackendID, Bool) -> String?)?
    var pause: ((UUID) async throws -> Void)?
    var resume: ((UUID) async throws -> Void)?
    var cancel: ((UUID) async throws -> Void)?
    var clearPartial: ((UUID) async throws -> Void)?
    var loading = false
    var loadError: String?
    func canEdit(_ location: ASRBackendLocation) -> Bool {
        switch location { case .native: false; case .loopbackService: saveLocal != nil && discovery != nil && credential != nil; case .cloud: saveCloud != nil && draftChecks != nil && credential != nil && hasCredential != nil }
    }
    func canAcquire(_ entry: ASRAcquisitionEntry) -> Bool {
        switch entry {
        case .recommended, .huggingFace: hfSession != nil && saveHFToken != nil
        case .directory: importedActions != nil && chooseDirectory != nil && persistImported != nil
        case .localService: canEdit(.loopbackService)
        case .cloudService: canEdit(.cloud)
        }
    }
    /// Production calls this closure only after the user chooses the import entry.
    static func openDirectory() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "检查模型目录"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct ASRModelCenterView: View {
    @ObservedObject var model: ASRModelCenterViewModel
    var actions = ASRModelCenterUIActions()
    @State private var filter = "all"
    @State private var sheet: Sheet?
    @State private var message: String?
    private struct Sheet: Identifiable {
        enum Kind { case recommendations, hf, directory, local(LocalASRServiceDraft), cloud(ASRProviderDraft) }
        let id = UUID()
        let kind: Kind
    }
    init(model: ASRModelCenterViewModel, actions: ASRModelCenterUIActions = .init(), initialSource: String = "all") {
        self.model = model; self.actions = actions; _filter = State(initialValue: initialSource)
    }
    private var config: Configuration? { actions.configuration?() }
    private var rows: [ASRModelCenterRow] { model.rows.filter { filter == "all" || $0.location.rawValue == filter } }
    private var selected: ASRModelCenterRow? { model.rows.first { $0.id == model.selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionSummary
            if let reason = actions.loadError { Text(reason).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if model.isBusy { Label("操作进行中；请等待验证与计算结束。仍可浏览和管理安装任务。", systemImage: "hourglass").foregroundStyle(.secondary) }
            if let busy = model.busyNotice { Text(busy).foregroundStyle(.secondary) }
            if let notice = model.notice { Text(notice).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text("模型库").font(Theme.Typography.sectionTitle)
                Spacer()
                Picker("模型来源", selection: $filter) {
                    Text("全部").tag("all")
                    Text("离线模型").tag(ASRBackendLocation.native.rawValue)
                    Text("本机服务").tag(ASRBackendLocation.loopbackService.rawValue)
                    Text("云端服务").tag(ASRBackendLocation.cloud.rawValue)
                }.labelsHidden().frame(width: 120)
            }
            HStack(spacing: 0) {
                library.frame(minWidth: 190, idealWidth: 230, maxWidth: 270)
                Divider()
                if let selected {
                    ASRModelDetail(row: selected, model: model, config: config, actions: actions, edit: { edit(selected.id) })
                        .id(selected.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform").font(.system(size: 25)).foregroundStyle(Theme.accentText)
                        Text("选择模型查看详情").fontWeight(.medium)
                        Text("下载、配置与试用分别进行。\n浏览模型不会更改主选。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(18)
                }
            }.frame(height: 390).background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))
            acquisition
            Divider()
            ModelInstallationList(installations: model.installations, actions: actions, refresh: { await model.refreshInstallations() }, selectedJobID: model.selectedInstallationID)
        }.font(Theme.Typography.description).tint(Theme.accent)
            .sheet(item: $sheet) { item in sheetContent(item.kind) }
    }
    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                role("主选", row: model.rows.first { $0.isPrimary })
                role("备选", row: model.rows.first { $0.isFallback })
                Spacer(minLength: 0)
            }
            if let config {
                Picker("识别策略", selection: Binding(get: { config.asrRoutingPolicy }, set: { model.changePolicy($0) })) {
                    Text("仅本地").tag(ASRRoutingPolicy.localOnly)
                    Text("自动").tag(ASRRoutingPolicy.auto)
                    Text("仅云端").tag(ASRRoutingPolicy.cloudOnly)
                }.pickerStyle(.segmented).frame(maxWidth: 300).disabled(model.isBusy)
                Toggle("允许云端备选上传识别音频（可能收费）", isOn: Binding(get: { ASRBackendMigration.selection(from: config).allowsCloudFallback }, set: { model.setAllowsCloudFallback($0) }))
                    .toggleStyle(.checkbox).disabled(model.isBusy)
            } else { Text("配置尚未接线；策略与获取操作暂不可用。").foregroundStyle(.secondary) }
        }
    }
    private func role(_ title: String, row: ASRModelCenterRow?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            if let row { Button(row.title) { model.selectedID = row.id }.buttonStyle(.link).font(.system(size: 12, weight: .medium)).lineLimit(2) }
            else { Text("未选择").foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var library: some View {
        VStack(spacing: 0) {
            if actions.loading { ProgressView("正在读取模型库…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if rows.isEmpty {
                VStack(spacing: 8) { Text("尚无此来源的模型").fontWeight(.medium); Text("从下方获取模型，或切换来源筛选。").foregroundStyle(.secondary) }
                    .multilineTextAlignment(.center).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(rows) { row in
                            Button { model.selectedID = row.id } label: {
                                ASRModelRow(row: row).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9)
                                    .background(model.selectedID == row.id ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(row.id)
                                .accessibilityAddTraits(model.selectedID == row.id ? .isSelected : [])
                        }
                    }.padding(7)
                }.focusable().onMoveCommand(perform: moveSelection).accessibilityLabel("识别模型库，使用上下方向键选择")
            }
        }
    }
    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == model.selectedID }
        let next = current.map { min(rows.count - 1, max(0, $0 + (direction == .up ? -1 : 1))) } ?? 0
        model.selectedID = rows[next].id
    }
    private var acquisition: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("获取模型").font(Theme.Typography.sectionTitle)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { acquisitionButtons }
                VStack(alignment: .leading, spacing: 7) {
                    HStack { acquisitionButton(.recommended); acquisitionButton(.huggingFace); acquisitionButton(.directory) }
                    HStack { acquisitionButton(.localService); acquisitionButton(.cloudService) }
                }
            }
            if ASRAcquisitionEntry.allCases.contains(where: { !actions.canAcquire($0) }) {
                Text("部分获取入口尚未配置，暂不可用。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var acquisitionButtons: some View { ForEach(ASRAcquisitionEntry.allCases) { acquisitionButton($0) } }
    private func acquisitionButton(_ entry: ASRAcquisitionEntry) -> some View {
        Button(entry.title) { acquire(entry) }.controlSize(.small).disabled(!actions.canAcquire(entry) || (entry == .directory && model.isBusy))
            .help(actions.canAcquire(entry) ? entry.title : "应用尚未配置此获取入口")
    }
    private func acquire(_ entry: ASRAcquisitionEntry) {
        switch entry {
        case .recommended: sheet = .init(kind: .recommendations)
        case .huggingFace: sheet = .init(kind: .hf)
        case .directory:
            guard let directory = actions.chooseDirectory?(), let imported = actions.importedActions else { return }
            imported.stage(directory: directory); sheet = .init(kind: .directory)
        case .localService:
            let profile = LocalASRServicePreset.customOpenAICompatible.makeProfile(baseURL: "http://127.0.0.1:8000/v1", modelID: nil)
            sheet = .init(kind: .local(.init(target: .new(profile.id), profile: profile)))
        case .cloudService:
            let profile = CloudASRVendor.makeProfile(.openAI, isActive: false)
            sheet = .init(kind: .cloud(.init(target: .new(profile.id), profile: profile)))
        }
    }
    private func edit(_ id: ASRBackendID) {
        if let profile = config?.localASRServices.first(where: { "service:" + $0.id.uuidString == id.rawValue }) { sheet = .init(kind: .local(.init(target: .existing(profile.id), profile: profile))) }
        if let profile = config?.cloudASRConfig.providers.first(where: { "cloud:" + $0.id.uuidString == id.rawValue }) { sheet = .init(kind: .cloud(.init(target: .existing(profile.id), profile: profile))) }
    }
    @ViewBuilder private func sheetContent(_ kind: Sheet.Kind) -> some View {
        switch kind {
        case .recommendations:
            VStack(alignment: .leading, spacing: 14) {
                Text("推荐的原生模型").font(.system(size: 16, weight: .semibold))
                Text("先查看资源取舍，再预览固定版本和完整下载大小。下载后仍需明确试用。").foregroundStyle(.secondary)
                ForEach(ASRModelRecipes.all, id: \.id) { recipe in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) { Text(recipe.displayName).fontWeight(.medium); Text(recipe.acquisitionNote).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        Spacer()
                        Button("查看下载") { actions.hfSession?.useRecipe(recipe); sheet = .init(kind: .hf) }
                    }; Divider()
                }
                Button("关闭") { sheet = nil }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 560)
        case .hf:
            if let session = actions.hfSession, let saveToken = actions.saveHFToken { HFModelInstallSheet(session: session, saveToken: saveToken, onClose: { sheet = nil }) }
        case .directory:
            if let imported = actions.importedActions { directoryPreview(imported) }
        case .local(let draft):
            if let discovery = actions.discovery, let save = actions.saveLocal, let credential = actions.credential {
                LocalASRServiceEditSheet(draft: draft, discovery: discovery, navigation: actions.navigation,
                    storedCredential: { try credential(.init(rawValue: "service:" + draft.target.id.uuidString)) },
                    onSave: { value in try save(value); saved(.init(rawValue: "service:" + value.target.id.uuidString)) }, onCancel: { sheet = nil })
            }
        case .cloud(let draft):
            if let checks = actions.draftChecks, let save = actions.saveCloud, let credential = actions.credential {
                ASRProviderEditSheet(draft: draft, checks: checks, navigation: actions.navigation, hadStoredKey: actions.hasCredential?(.init(rawValue: "cloud:" + draft.target.id.uuidString)) ?? false,
                    storedKey: { try credential(.init(rawValue: "cloud:" + draft.target.id.uuidString)) ?? "" },
                    onSave: { value in try save(value); saved(.init(rawValue: "cloud:" + value.target.id.uuidString)) }, onCancel: { sheet = nil })
            }
        }
    }
    private func saved(_ id: ASRBackendID) {
        model.refresh()
        var projectedID = id
        if id.rawValue.hasPrefix("native:import:"), let uuid = UUID(uuidString: String(id.rawValue.dropFirst("native:import:".count))),
           let config, let imported = config.importedASRModels.first(where: { $0.id == uuid }) {
            projectedID = ASRModelCenterPresentation.nativeID(for: imported, records: config.installedASRModels)
        }
        model.selectedID = model.rows.contains(where: { $0.id == projectedID }) ? projectedID : nil
        sheet = nil
    }
    private func directoryPreview(_ imported: ImportedASRModelActions) -> some View {
        ASRDirectoryPreview(actions: imported, save: {
            guard let persist = actions.persistImported else { throw ProviderDraftCommitError.invalid("模型库保存尚未接线。") }
            let id = try imported.savePreview(persist: persist); saved(id)
        }, cancel: { imported.cancelInspection(); sheet = nil })
    }
}

/// Inspection preview observes the existing C2 owner; no filesystem or runtime work occurs here.
private struct ASRDirectoryPreview: View {
    @ObservedObject var actions: ImportedASRModelActions
    let save: () throws -> Void
    let cancel: () -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("检查本地模型目录").font(.title3)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if actions.isInspecting { ProgressView("正在检查格式与完整性…") }
                    if let preview = actions.preview {
                        Text(preview.model.name).fontWeight(.medium)
                        Text(preview.model.engine.rawValue + " · " + preview.model.variant)
                        Text(preview.model.directory.path).textSelection(.enabled)
                        Text("\(preview.model.sizeBytes) 字节 · 不复制权重")
                        Text(preview.assessment.explanation).fixedSize(horizontal: false, vertical: true)
                        Text("加入后不会测试或选择。移除记录不删除原目录。")
                    }
                    if let message = actions.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                    if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("仅加入模型库") { do { try save() } catch { self.error = error.localizedDescription } }
                    .buttonStyle(.borderedProminent).disabled(actions.isInspecting || actions.preview == nil || actions.preview?.assessment.compatibility == .incompatible)
            }
        }.padding(20).frame(width: 550, height: 420)
    }
}
