import SwiftUI

extension SettingsPage {
    var asrSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
                Text("语音转文字（ASR）")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            Text("Flowtype 使用本地 Qwen3-ASR 模型进行语音识别，AppleSpeech 作为兜底方案。所有识别均在本地完成，无需联网。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            QwenModelStatusCard()

            // Language selector
            HStack {
                Text("识别语言")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $store.current.asrLanguage) {
                    ForEach(WhisperLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // Microphone device selector
            HStack {
                Text("麦克风设备")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    if selectedDeviceUnavailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    Picker("", selection: $store.current.microphoneDeviceID) {
                        Text("系统默认").tag(String?.none)
                        ForEach(availableDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }
            }
            .onAppear {
                refreshDevices()
            }
        }
        .padding(.horizontal, 4)
    }
}
