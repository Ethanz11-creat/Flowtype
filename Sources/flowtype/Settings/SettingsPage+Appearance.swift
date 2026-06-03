import SwiftUI

extension SettingsPage {
    var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("外观")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            Picker("", selection: Binding(
                get: { store.current.appearancePreference },
                set: { newValue in
                    store.current.appearancePreference = newValue
                    AppearanceController.apply(newValue)
                }
            )) {
                ForEach(AppearancePreference.allCases) { pref in
                    Text(pref.displayName).tag(pref)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)

            Text("浅色 / 深色 固定外观，随系统则跟随 macOS 自动切换。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
