import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// A single cached monochrome noise tile, generated once. Tiling this at low opacity with
/// `.softLight` is the "matte" tell that stops translucent material from looking like cheap glass.
enum GrainTexture {
    static let image: Image = {
        let side = 180
        let ctx = CIContext(options: nil)
        let noise = CIFilter.randomGenerator().outputImage ?? CIImage.empty()
        let mono = noise
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputBrightnessKey: 0.0,
                kCIInputContrastKey: 1.0,
            ])
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        if let cg = ctx.createCGImage(mono, from: CGRect(x: 0, y: 0, width: side, height: side)) {
            return Image(decorative: cg, scale: 1, orientation: .up)
        }
        return Image(systemName: "circle")   // fallback (never hit in practice)
    }()
}

struct GrainOverlay: ViewModifier {
    var opacity: Double = 0.04
    func body(content: Content) -> some View {
        content.overlay(
            GrainTexture.image
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.softLight)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
    }
}

extension View {
    /// Overlay the cached grain texture (default 4%). Call once at the window-shell level.
    func grain(_ opacity: Double = 0.04) -> some View { modifier(GrainOverlay(opacity: opacity)) }
}
