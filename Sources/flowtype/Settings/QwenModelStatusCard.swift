import SwiftUI
import AppKit

// MARK: - Qwen3-ASR Status Card

struct QwenModelStatusCard: View {
    @ObservedObject private var modelState = QwenModelState.shared
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var folderMessage: String?

    private let modelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    private let hfCommand = #"HF_ENDPOINT=https://hf-mirror.com hf download aufklarer/Qwen3-ASR-0.6B-MLX-4bit --local-dir "~/Library/Caches/qwen3-speech/aufklarer_Qwen3-ASR-0.6B-MLX-4bit""#

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            progressArea
            Divider().opacity(0.5)
            sourcePicker
            folderPicker
        }
        .padding(14)
        .glassCard(cornerRadius: 10)
    }

    // MARK: Header (status + primary action)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 16))
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(statusColor)
                Text(modelId)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            switch modelState.status {
            case .error:    loadButton("重试")
            case .notLoaded: loadButton("加载模型")
            default:        EmptyView()
            }
        }
    }

    // MARK: Progress / stalled / error

    @ViewBuilder private var progressArea: some View {
        switch modelState.status {
        case .downloading(let progress, let mbps, let eta):
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(height: 4)
            Text(downloadDetail(progress: progress, mbps: mbps, eta: eta))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
        case .loading:
            ProgressView().progressViewStyle(.linear).frame(height: 4)
            Text("加载到内存中…").font(.system(size: 10)).foregroundColor(.secondary)
        case .stalled:
            Text("下载停滞，正在自动重试…").font(.system(size: 11)).foregroundColor(.orange)
        case .error(let reason, _):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason).font(.system(size: 11)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("或用命令行下载后「指定文件夹」：").font(.system(size: 10)).foregroundColor(.secondary)
                    Button("复制命令") { copy(hfCommand) }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                Text(hfCommand)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Download source

    private var sourcePicker: some View {
        HStack(spacing: 8) {
            Text("下载源").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { sourceSelection },
                set: { store.current.downloadSource = $0 }
            )) {
                Text("自动").tag(DownloadSource.auto)
                Text("官方").tag(DownloadSource.official)
                Text("镜像").tag(DownloadSource.mirror)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            Spacer()
        }
    }

    /// Map any persisted source (incl. .custom) onto one of the three segments for display.
    private var sourceSelection: DownloadSource {
        switch store.current.downloadSource {
        case .auto: return .auto
        case .mirror: return .mirror
        default: return .official   // official / custom → show the 官方 segment
        }
    }

    // MARK: Specify model folder

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("指定模型文件夹") { pickModelFolder() }
                    .controlSize(.small)
                if let path = store.current.localModelPath {
                    Button {
                        store.current.localModelPath = nil
                        folderMessage = nil
                    } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.borderless)
                    Text(path).font(.system(size: 10)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            if let msg = folderMessage {
                Text(msg).font(.system(size: 10)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("已下好模型的话，指到那个文件夹即可离线加载（不再下载）。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Actions

    private func pickModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择已下载的 Qwen3-ASR 模型文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if ModelLocator.validateComplete(url) {
            store.current.localModelPath = url.path
            folderMessage = nil
            reload()
        } else {
            folderMessage = "所选文件夹不完整（需含 config.json、权重 *.safetensors、分词器）"
        }
    }

    private func reload() {
        Task {
            let provider = SessionController.shared.qwenProvider
            await modelState.loadModel(provider: provider)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func loadButton(_ title: String) -> some View {
        Button(title) { reload() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }

    // MARK: Display helpers

    private func downloadDetail(progress: Double, mbps: Double, eta: Int) -> String {
        var s = "下载中 \(Int(progress * 100))%"
        if mbps > 0.01 { s += " · \(String(format: "%.1f", mbps)) MB/s" }
        if eta > 0 { s += eta >= 60 ? " · 剩余 ~\(eta / 60)m\(eta % 60)s" : " · 剩余 ~\(eta)s" }
        return s
    }

    private var statusIcon: String {
        switch modelState.status {
        case .ready: return "checkmark.circle.fill"
        case .downloading, .loading: return "arrow.triangle.2.circlepath"
        case .stalled: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .notLoaded: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch modelState.status {
        case .ready: return .green
        case .downloading, .loading, .notLoaded: return .orange
        case .stalled: return .orange
        case .error: return .red
        }
    }

    private var statusTitle: String {
        switch modelState.status {
        case .ready: return "Qwen3-ASR 就绪"
        case .downloading(let p, _, _): return "下载中 \(Int(p * 100))%"
        case .stalled: return "下载停滞"
        case .loading: return "加载中…"
        case .error: return "加载失败"
        case .notLoaded: return "未加载"
        }
    }
}
