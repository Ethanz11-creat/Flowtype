import SwiftUI

struct CapsuleView: View {
    @EnvironmentObject var session: SessionController
    // The preview supplies only presentation data; the native production layout/material
    // and actual AudioVisualizer remain the same as in the floating panel.
    var presentationOverride: CapsulePresentation? = nil

    private let purple = Color(red: 0.522, green: 0.361, blue: 1)
    private let blue = Color(red: 0.302, green: 0.631, blue: 1)
    private var presentation: CapsulePresentation { presentationOverride ?? session.capsulePresentation }
    private var isRecovery: Bool { presentation.size.height == 156 }

    var body: some View {
        let p = presentation
        HStack(spacing: 12) {
            indicator(p.indicator)
                .frame(width: 40, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(isRecovery ? 2 : 1)
                HStack(spacing: 4) {
                    if let timer = p.timer {
                        Text(timer).fixedSize(horizontal: true, vertical: false)
                    }
                    Text(p.subtitle)
                        .lineLimit(isRecovery ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.82, green: 0.83, blue: 0.96))
                if isRecovery, let card = session.recoveryCard, presentationOverride == nil {
                    recoveryActions(p.actions) { session.performRecoveryAction($0, cardID: card.id) }
                } else if isRecovery, !p.actions.isEmpty {
                    recoveryActions(p.actions) { _ in }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isRecovery ? 28 : 16)
        .frame(width: p.size.width, height: p.size.height)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                Color(red: 0.12, green: 0.11, blue: 0.16).opacity(0.66)
                RadialGradient(colors: [purple.opacity(0.27), purple.opacity(0.05), .clear],
                    center: .center, startRadius: 18, endRadius: isRecovery ? 210 : 145)
                LinearGradient(colors: [.clear, blue.opacity(0.07)], startPoint: .leading, endPoint: .trailing)
            }
        }
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(LinearGradient(colors: [.white.opacity(0.30), purple.opacity(0.52), blue.opacity(0.40), .white.opacity(0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .shadow(color: purple.opacity(0.28), radius: 15)
        .shadow(color: blue.opacity(0.10), radius: 25)
        .opacity(p.hidden ? 0 : 1)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func indicator(_ indicator: CapsulePresentation.Indicator) -> some View {
        switch indicator {
        case .waveform: AudioVisualizer()
        case .spinner:
            ProgressView().progressViewStyle(.circular).controlSize(.small).tint(purple)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: isRecovery ? 23 : 19, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [purple, blue], startPoint: .leading, endPoint: .trailing))
        }
    }

    private func recoveryActions(_ actions: [RecoveryAction], perform: @escaping (RecoveryAction) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(actions, id: \.self) { action in
                Button(action.displayName) { perform(action) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.73, green: 0.78, blue: 1))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 5)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
