import SwiftUI

// MARK: - Provider Selector

struct ProviderPicker: View {
    @Binding var provider: String
    @Binding var baseURL: String

    var body: some View {
        Picker("服务商", selection: $provider) {
            ForEach(ProviderPreset.all, id: \.id) { preset in
                Text(preset.name).tag(preset.name)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: provider) { _, newValue in
            if let preset = ProviderPreset.all.first(where: { $0.name == newValue }),
               !preset.isCustom {
                if baseURL.isEmpty || ProviderPreset.all.contains(where: { $0.baseURL == baseURL && !$0.isCustom }) {
                    baseURL = preset.baseURL
                }
            }
        }
    }
}

// MARK: - API Key Field

struct SecureKeyField: View {
    let title: String
    @Binding var key: String
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Group {
                    if isVisible {
                        TextField("输入 API Key", text: $key)
                    } else {
                        SecureField("输入 API Key", text: $key)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                Button(action: { isVisible.toggle() }) {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Model ID Field

struct ModelIDField: View {
    let title: String
    @Binding var model: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            TextField(placeholder, text: $model)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
    }
}
