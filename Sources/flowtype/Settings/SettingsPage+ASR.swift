import SwiftUI

extension SettingsPage {
    var asrSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("语音转文字（ASR）")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            Text("Flowtype 支持本地和云端两种语音识别引擎。本地识别使用 Qwen3-ASR 模型，完全离线运行；云端识别通过 OpenAI 兼容接口调用云端 ASR 服务。录音中实时预览使用 Apple Speech，始终在本地完成。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $store.current.asrEngine) {
                Text("本地识别").tag(ASREngineType.local)
                Text("云端识别").tag(ASREngineType.cloud)
            }
            .pickerStyle(.segmented)

            switch store.current.asrEngine {
            case .local:
                LocalModelPicker()
                ASRModelStatusCard()
            case .cloud:
                CloudASRProviderList()
                ASRModelStatusCard()
            }

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

            Text("录音中实时预览使用 Apple Speech，始终在本地完成")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
