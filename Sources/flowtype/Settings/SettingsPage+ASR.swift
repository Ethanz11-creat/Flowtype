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

            Text("Flowtype 同时支持本地（Qwen3-ASR MLX / Whisper Core ML，离线）与云端（硅基流动、OpenAI、自定义兼容接口 / Paraformer 实时）识别。自动模式下默认优先云端，网络不佳时无感切换到本地兜底；成功加载本地模型后，断网时可离线识别且音频不出设备。")
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

            HStack {
                Text("云端发送上下文")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("", isOn: $store.current.cloudASRSendContext)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(store.current.asrRoutingPolicy == .localOnly)
            }
            HStack {
                Text("云端整理使用上下文")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("", isOn: $store.current.cloudPolishSendContext)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!store.current.cloudASRSendContext || store.current.asrRoutingPolicy == .localOnly)
            }
            Text("云端发送上下文是总开关：开启后，支持上下文的 HTTP 识别可携带前台文本；整理还需单独开启。Paraformer 实时识别不发送上下文。仅本地模式不向云端发送前台上下文；音频仅在云端识别时离开设备。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
