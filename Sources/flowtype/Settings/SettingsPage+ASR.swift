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

            Text("Flowtype 同时支持本地（Qwen3-ASR，离线）与云端（OpenAI 兼容接口）识别。自动模式下默认优先云端，网络不佳时无感切换到本地兜底；断网时本地路径可用且音频不出设备。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $store.current.asrRoutingPolicy) {
                ForEach(ASRRoutingPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.segmented)

            switch store.current.asrRoutingPolicy {
            case .localOnly:
                LocalModelPicker()
                ASRModelStatusCard()
            case .cloudOnly:
                CloudASRProviderList()
                ASRModelStatusCard()
            case .auto:
                LocalModelPicker()
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

            HStack {
                Text("性能指标")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button("复制指标报告") {
                    let report = SessionMetrics.report(HistoryStore.shared.sessions)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("录音中实时预览使用 Apple Speech，始终在本地完成")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
