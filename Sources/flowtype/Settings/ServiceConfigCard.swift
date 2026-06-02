import SwiftUI

// MARK: - Service Config Card

struct ServiceConfigCard: View {
    let title: String
    let subtitle: String
    @Binding var provider: String
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var model: String
    let modelPlaceholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("服务商")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                ProviderPicker(provider: $provider, baseURL: $baseURL)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base URL")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("https://...", text: $baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            SecureKeyField(title: "API Key", key: $apiKey)

            ModelIDField(title: "模型 ID", model: $model, placeholder: modelPlaceholder)
        }
        .padding(16)
        .glassCard()
    }
}
