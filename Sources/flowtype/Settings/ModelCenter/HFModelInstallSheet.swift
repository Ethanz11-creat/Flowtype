import SwiftUI

struct HFModelInstallInput: Equatable {
    var repository = ""
    var revision = ""
    var variant = ""
    var tokenizerRepository = ""
    var tokenizerRevision = ""
    var source: DownloadSource = .official
    var usesStoredToken = false
}

@MainActor
final class HFModelInstallSession: ObservableObject {
    struct Preview {
        let input: HFModelInstallInput
        let repository: HFResolvedRepository
        let tokenizer: HFResolvedRepository?
        let plan: ASRInstallPlan
    }
    @Published var input = HFModelInstallInput() { didSet { if input != oldValue { preview = nil; message = nil } } }
    @Published private(set) var preview: Preview?
    @Published private(set) var variants: [String] = []
    @Published private(set) var message: String?
    @Published private(set) var isWorking = false
    @Published private(set) var jobID: UUID?
    typealias Resolve = (HFRepositorySelection, URL, String?) async throws -> HFResolvedRepository
    typealias Plan = (HFResolvedRepository, String?, HFResolvedRepository?, String?) async throws -> ASRInstallPlan
    private let resolve: Resolve
    private let plan: Plan
    private let enqueue: (ASRInstallPlan) async throws -> UUID
    private let beginPreview: () -> Void
    init(resolve: @escaping Resolve, plan: @escaping Plan, enqueue: @escaping (ASRInstallPlan) async throws -> UUID,
         beginPreview: @escaping () -> Void = {}) {
        self.resolve = resolve; self.plan = plan; self.enqueue = enqueue; self.beginPreview = beginPreview
    }
    /// The session owns metadata previews only; B4 retains every download after dismissal.
    convenience init(credentialStore: any ASRCredentialStore, installer: ModelInstallationCoordinator) {
        self.init(makeClient: { HFRepositoryClient(downloadEndpoint: $0, credentialStore: credentialStore) },
            enqueue: { try await installer.enqueue($0) })
    }
    /// Uses the same preview composition with an injected metadata transport for focused fixtures.
    convenience init(makeClient: @escaping (URL) -> HFRepositoryClient,
                     enqueue: @escaping (ASRInstallPlan) async throws -> UUID) {
        let clients = Clients(makeClient: makeClient)
        self.init(resolve: { selection, endpoint, credential in
            try await clients.client(endpoint).resolve(selection, credentialID: credential)
        }, plan: { repository, variant, tokenizer, credential in
            try await ASRInstallPlanner(client: clients.client(repository.downloadEndpoint)).plan(
                repository: repository, variant: variant, tokenizer: tokenizer, credentialID: credential)
        }, enqueue: enqueue, beginPreview: { clients.values.removeAll() })
    }
    private final class Clients {
        let makeClient: (URL) -> HFRepositoryClient
        var values: [URL: HFRepositoryClient] = [:]
        init(makeClient: @escaping (URL) -> HFRepositoryClient) { self.makeClient = makeClient }
        func client(_ endpoint: URL) -> HFRepositoryClient {
            if let value = values[endpoint] { return value }
            let value = makeClient(endpoint)
            values[endpoint] = value
            return value
        }
    }
    func useRecipe(_ recipe: ASRModelRecipe) {
        guard !isWorking, let model = recipe.sources.first else { return }
        input = .init(repository: model.repoID, revision: model.requestedRevision,
            variant: recipe.variant ?? "", tokenizerRepository: recipe.sources.dropFirst().first?.repoID ?? "",
            tokenizerRevision: recipe.sources.dropFirst().first?.requestedRevision ?? "", source: input.source)
    }
    func preparePreview() async {
        guard !isWorking else { return }
        // B1 contexts belong to one metadata preview; its model/tokenizer/planner still
        // share clients, while a fresh attempt releases all prior endpoint contexts.
        beginPreview()
        isWorking = true; preview = nil; message = nil; jobID = nil; variants = []
        defer { isWorking = false }
        let captured = input
        do {
            let endpoint = try captured.source.validatedEndpoint(isChina: DownloadSource.systemIsLikelyChina())
            let credential = captured.usesStoredToken ? "asr.hf.official" : nil
            let selection = try HFRepositoryInput.parse(captured.repository,
                revision: captured.revision.isEmpty ? nil : captured.revision)
            let repository = try await resolve(selection, endpoint, credential)
            guard input == captured else { return }
            variants = Array(Set(repository.files.compactMap { file -> String? in
                let parts = file.remotePath.split(separator: "/")
                guard parts.count > 2, parts[1].hasSuffix(".mlmodelc") || parts[1].hasSuffix(".mlpackage") else { return nil }
                return String(parts[0])
            })).sorted()
            let tokenizer: HFResolvedRepository?
            if captured.tokenizerRepository.isEmpty { tokenizer = nil }
            else {
                tokenizer = try await resolve(HFRepositoryInput.parse(captured.tokenizerRepository,
                    revision: captured.tokenizerRevision.isEmpty ? nil : captured.tokenizerRevision), endpoint, credential)
            }
            let result = try await plan(repository, captured.variant.isEmpty ? nil : captured.variant, tokenizer, credential)
            try Task.checkCancellation()
            guard input == captured else { return }
            preview = .init(input: captured, repository: repository, tokenizer: tokenizer, plan: result)
        } catch is CancellationError { if input == captured { message = "已取消元数据查询，输入已保留。" } }
        catch { if input == captured { message = Self.safeMessage(error) } }
    }
    func confirmInstall() async {
        guard !isWorking, jobID == nil, let preview, preview.input == input else { return }
        isWorking = true; message = nil
        defer { isWorking = false }
        do { jobID = try await enqueue(preview.plan) }
        catch { message = "无法加入安装队列；预览和输入已保留，请检查安装任务后重试。" }
    }
    static func safeMessage(_ error: Error) -> String {
        if let error = error as? ASRInstallPlanningError { return error.localizedDescription }
        if let error = error as? HFRepositoryInputError {
            if case .requiresSelection = error { return "此 tree/blob 链接的版本边界不明确，请完整填写 revision 后重试。" }
            return "仓库输入无效；请输入 Hugging Face 模型仓库 ID 或官方 HTTPS 链接，并检查 revision。"
        }
        if let error = error as? HFRepositoryError, error == .unauthorized || error == .forbidden {
            return "仓库需要授权。请在浏览器接受许可，并单独保存 Hugging Face token 后重试。镜像不接收此 token。"
        }
        return "无法查询模型元数据；请检查仓库、固定版本、下载源或授权后重试。"
    }
}

/// C3 presents this sheet from both recommended recipes and arbitrary HF input.
struct HFModelInstallSheet: View {
    @ObservedObject var session: HFModelInstallSession
    let saveToken: (String) throws -> Void
    let onClose: () -> Void
    @State private var token = ""
    @State private var tokenNotice: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从 Hugging Face 获取离线模型").font(.title3)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("仓库 ID 或 HTTPS 链接", text: $session.input.repository)
                    TextField("Revision（默认 main；tree/blob 链接须明确填写）", text: $session.input.revision)
                    TextField("变体 / 子目录（多变体须选择）", text: $session.input.variant)
                    if !session.variants.isEmpty {
                        ForEach(session.variants, id: \.self) { variant in
                            Button(variant) { session.input.variant = variant }
                        }
                    }
                    TextField("Whisper tokenizer 仓库（需要时填写）", text: $session.input.tokenizerRepository)
                    TextField("Tokenizer revision（默认 main）", text: $session.input.tokenizerRevision)
                    Picker("下载源", selection: $session.input.source) {
                        Text("自动（按区域选择）").tag(DownloadSource.auto)
                        Text("官方").tag(DownloadSource.official)
                        Text("镜像（匿名）").tag(DownloadSource.mirror)
                        Text("自定义（匿名）").tag(customSource)
                    }
                    if case .custom = session.input.source {
                        TextField("自定义 HTTPS 下载源", text: Binding(get: {
                            if case .custom(let value) = session.input.source { return value }; return ""
                        }, set: { session.input.source = .custom($0) }))
                    }
                    DisclosureGroup("Hugging Face 授权") {
                        VStack(alignment: .leading) {
                            SecureField("HF token（单独保存，不进入安装计划）", text: $token)
                            Button("保存 token 并用于官方源") {
                                do { try saveToken(token); token = ""; session.input.usesStoredToken = true; tokenNotice = "凭据已单独保存。" }
                                catch { tokenNotice = "凭据未能保存，请重试。" }
                            }.disabled(token.isEmpty)
                            Toggle("使用已保存的 HF token（仅官方域名）", isOn: $session.input.usesStoredToken)
                            if let selection = try? HFRepositoryInput.parse(session.input.repository,
                                revision: session.input.revision.isEmpty ? nil : session.input.revision),
                               let url = URL(string: "https://huggingface.co/" + selection.repoID) {
                                Link("在浏览器打开仓库许可 / 授权", destination: url)
                            }
                            if let tokenNotice { Text(tokenNotice) }
                        }
                    }
                    Button("查询元数据与预览") { Task { await session.preparePreview() } }
                    if let preview = session.preview {
                        source(preview.repository)
                        if let tokenizer = preview.tokenizer { source(tokenizer) }
                        Text("完整下载量：\(ByteCountFormatter.string(fromByteCount: preview.plan.totalBytes, countStyle: .file))（\(preview.plan.totalBytes) bytes，\(preview.plan.files.count) 个文件）")
                        Text("兼容范围：\(preview.plan.engine.rawValue)。元数据通过仅表示候选兼容；安装后还须严格检查、加载与试识别。")
                    }
                    if let message = session.message { Text(message).foregroundStyle(.red) }
                    if let id = session.jobID { Text("已加入安装任务：\(id.uuidString)。安装完成后可显式试用；此操作不切换主选。") }
                }.textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("关闭", action: onClose)
                Spacer()
                if session.isWorking { ProgressView().controlSize(.small) }
                Button("确认下载") { Task { await session.confirmInstall() } }
                    .disabled(session.preview == nil || session.jobID != nil)
            }
        }.padding(20).frame(width: 580, height: 620)
            .disabled(session.isWorking)
    }
    private var customSource: DownloadSource {
        if case .custom = session.input.source { return session.input.source }
        return .custom("")
    }
    private func source(_ repository: HFResolvedRepository) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repository.selection.repoID)
            Text("固定 commit：" + repository.commit).textSelection(.enabled)
            Text("下载源：" + repository.downloadEndpoint.absoluteString).textSelection(.enabled)
            if let license = repository.licenseURL { Link("查看来源许可证（安装前请确认）", destination: license) }
            else { Text("来源未提供许可证链接；请在仓库确认使用与再分发条件。").foregroundStyle(.orange) }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// C3's five buttons all lead to the acquisition flows; none starts recognition implicitly.
enum ASRAcquisitionEntry: String, CaseIterable, Identifiable {
    case recommended, huggingFace, directory, localService, cloudService
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recommended: "推荐模型"
        case .huggingFace: "从 Hugging Face 下载"
        case .directory: "导入本地目录"
        case .localService: "连接本机服务"
        case .cloudService: "添加云端服务"
        }
    }
}

extension ASRModelRecipe {
    var acquisitionNote: String {
        let tradeoff: String
        switch id {
        case "qwen3-0.6b-4bit": tradeoff = "较小体积与内存需求；适合优先考虑资源占用。"
        case "qwen3-1.7b-4bit": tradeoff = "较高资源需求；请先查看硬件评估与实际转写。"
        case "whisper-tiny": tradeoff = "较小的多语言候选；速度与质量须在你的设备评估。"
        default: tradeoff = "比 tiny 需要更多资源；质量取舍须查看实际输出。"
        }
        return tradeoff + (verified ? "已通过对应原生验证矩阵；本次加载仍须验证。" : "候选配方，实际模型验证待完成。")
    }
}
