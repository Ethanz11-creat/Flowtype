import SwiftUI

// MARK: - Qwen3-ASR Status Card

struct QwenModelStatusCard: View {
    @ObservedObject private var modelState = QwenModelState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 16))
                    .foregroundColor(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(statusColor)
                    Text("aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if case .error = modelState.status {
                    loadButton("重试")
                } else if case .notLoaded = modelState.status {
                    loadButton("加载模型")
                }
            }

            if case .downloading(let progress, let detail) = modelState.status {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(height: 4)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if case .loading = modelState.status {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 4)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 10)
    }

    private func loadButton(_ title: String) -> some View {
        Button(title) {
            Task {
                let provider = SessionController.shared.qwenProvider
                await modelState.loadModel(provider: provider)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var statusIcon: String {
        switch modelState.status {
        case .ready: return "checkmark.circle.fill"
        case .downloading, .loading: return "arrow.triangle.2.circlepath"
        case .error: return "xmark.circle.fill"
        case .notLoaded: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch modelState.status {
        case .ready: return .green
        case .downloading, .loading, .notLoaded: return .orange
        case .error: return .red
        }
    }

    private var statusTitle: String {
        switch modelState.status {
        case .ready: return "Qwen3-ASR 就绪"
        case .downloading(let progress, _): return "下载中 \(Int(progress * 100))%"
        case .loading: return "加载模型中..."
        case .error: return "加载失败"
        case .notLoaded: return "等待加载"
        }
    }
}
