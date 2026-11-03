import SwiftUI

/// Presentation only: callers own configuration, permissions and any actions.
struct SettingsGroup<Content: View>: View {
    let title: String
    let description: String?
    private let content: Content

    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                if let description {
                    Text(description)
                        .font(Theme.Typography.description)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.cardBorder, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    let description: String?
    private let content: Content

    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                if let description {
                    Text(description)
                        .font(Theme.Typography.description)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            content
                .font(Theme.Typography.body)
        }
        .padding(.vertical, 12)
    }
}
