import SwiftUI

extension SettingsPage {
    var triggerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.orange)
                Text("触发键与交互")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("触发键")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Picker("", selection: $store.current.triggerKey) {
                        ForEach(TriggerKey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("交互模式")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Picker("", selection: $store.current.interactionMode) {
                        ForEach(InteractionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if store.current.interactionMode == .tapToStart {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("单击")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("停止录音，输出原始识别文本")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.purple)
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("双击")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("停止录音，输出润色后的文本")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("单击")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("开始 / 停止录音")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Spacer()
                }

                Text("当前触发键：\(store.current.triggerKey.displayName)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                // Audio feedback toggle
                HStack {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("录音开始/结束播放提示音")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("", isOn: $store.current.enableAudioFeedback)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}
