import SwiftUI
import AppKit

/// Window-level frosted material. `.behindWindow` blending samples the desktop behind a
/// transparent window, so the result is real frosted glass that adapts to light/dark.
struct FrostMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = .active
    }
}

/// The full window backdrop: translucent frosted material + a deep tint in dark mode + grain.
/// The dark tint pushes the frosted shell toward a near-black "deep frost" at night; light mode
/// is left untouched.
struct FrostBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FrostMaterial(material: .hudWindow, blending: .behindWindow)
            .overlay(scheme == .dark ? Color.black.opacity(0.5) : Color.clear)
            .grain(0.04)
            .ignoresSafeArea()
    }
}

extension View {
    /// Place the adaptive frosted-glass backdrop behind a window root.
    func frostWindowBackground() -> some View { background(FrostBackground()) }
}
