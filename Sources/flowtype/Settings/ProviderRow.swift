import SwiftUI

// MARK: - Provider Row

struct ProviderRow: View {
    let provider: LLMProvider
    let isActive: Bool
    let onSetActive: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle, testing, success, failure(String)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Text(provider.provider)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    Text(provider.model)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Connection test indicator
            HStack(spacing: 4) {
                switch testStatus {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }

                Button(action: {
                    Task {
                        await runTest()
                    }
                }) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(testStatus == .testing)
            }

            // Actions
            HStack(spacing: 6) {
                if !isActive {
                    Button("设为默认") {
                        onSetActive()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }

                Button("编辑") {
                    onEdit()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button("删除") {
                    onDelete()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.green.opacity(0.4) : Color.secondary.opacity(0.08), lineWidth: isActive ? 2 : 1)
        )
    }

    private func runTest() async {
        testStatus = .testing
        let service = LLMService()
        let result = await service.testConnection(provider: provider)
        await MainActor.run {
            switch result {
            case .success:
                testStatus = .success
            case .failure(let error):
                let msg: String
                switch error {
                case .apiError(let s): msg = s
                case .networkError(let e): msg = e.localizedDescription
                default: msg = "连接失败"
                }
                testStatus = .failure(msg)
            }
        }
    }
}
