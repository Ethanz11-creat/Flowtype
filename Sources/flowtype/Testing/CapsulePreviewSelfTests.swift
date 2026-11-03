#if DEBUG
import AppKit
import SwiftUI

/// Actual CapsuleView, isolated offscreen hosts. Fixtures never request mic, AX, network or clipboard.
enum CapsulePreviewSelfTests {
    private struct Record: Encodable {
        let file: String
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let title: String
        let subtitle: String
    }
    private struct Stage: PipelineStage {
        let name = "Capsule preview capture"
        let run: @MainActor @Sendable (SessionContext) async -> StageResult
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult { await run(context) }
    }
    @MainActor private final class Capture {
        var context: SessionContext?
        var continuation: CheckedContinuation<StageResult, Never>?
        func run(_ context: SessionContext) async -> StageResult {
            self.context = context
            context.markReady()
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish() { continuation?.resume(returning: .complete); continuation = nil }
    }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        let effects = ValidationEffects.live.snapshot
        let capture = Capture()
        let controller = SessionController(pipeline: [Stage(run: { await capture.run($0) })], observers: [],
            effects: .init(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in }),
            recoveryEffects: .init(openAccessibilitySettings: {}, openMicrophoneSettings: {}, openSpeechRecognitionSettings: {},
                openASRSettings: {}, openHistory: {}, copyText: { _ in }),
            configurationStore: ConfigurationStore(defaults: RuntimeEnvironment.defaults),
            refreshReadiness: { .ready }, readinessLevel: { .ready }, purpose: .trial, resources: SessionResourceCoordinator())
        defer { controller.cancel(); capture.finish() }
        do {
            let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("capsule-previews")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            controller.startRecording()
            for _ in 0..<100 {
                if capture.context != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            r.check(capture.context != nil, "capsule preview: isolated real recording context ready")
            var fixtures: [(String, CapsulePresentation)] = [
                ("recording", .init(state: .recording(elapsedSeconds: 12))),
                ("silent-recording", .init(state: .recording(elapsedSeconds: 12))),
                ("recording-countdown", .init(state: .recording(elapsedSeconds: 280), maxRecordingDuration: 300)),
                ("preparing", .init(state: .preparing)),
                ("preparing-diagnostic", .init(state: .preparing, preparationNotice: "首次使用 · 将请求麦克风权限")),
                ("processing", .init(state: .processing(provider: "synthetic"))),
                ("polishing", .init(state: .polishing(preview: "never rendered private preview"))),
                ("slow", .init(state: .polishing(preview: ""), slow: true)),
                ("injecting", .init(state: .injecting)),
                ("clipboard", .init(state: .notice("legacy"), notice: .clipboard)),
                ("no-speech", .init(state: .notice("legacy"), notice: .noSpeech)),
                ("empty-audio", .init(state: .notice("legacy"), notice: .emptyAudio)),
                ("polish-fallback", .init(state: .notice("legacy"), notice: .polishFallback(.failed))),
                ("resource-busy", .init(state: .notice("legacy"), notice: .resourceBusy))
            ]
            for (name, kind, hasAudio, textKind, event, history): (String, FailureKind, Bool, RecoveryTextKind, Bool, Bool) in [
                ("recoverable-error", .transientASR, true, .raw, false, false),
                ("error-long-diagnostic", .configuration(.unsupportedLanguage), false, .none, false, false),
                ("uncertain-delivery", .deliveryUncertain, false, .result, true, true),
                ("permission-error", .permission(.accessibility), false, .none, false, false)
            ] {
                let failure = RecoveryPolicy.presentation(kind: kind, resources: .init(stage: "ASR", hasAudio: hasAudio,
                    textKind: textKind, deliveryEventStarted: event, routingPolicy: .auto, hasHistory: history))
                fixtures.append((name, .init(state: .error(failure.message), recoveryCard: .init(id: UUID(), sessionID: 1, presentation: failure))))
            }
            var records: [Record] = []
            for (name, presentation) in fixtures {
                // Feed actual complete frames repeatedly while hosting the recording view.
                let voiced = name == "recording" || name == "recording-countdown"
                let feed = Task { @MainActor in
                    for _ in 0..<30 {
                        guard !Task.isCancelled else { return }
                        let samples: [Float] = voiced ? (0..<512).map { Float(sin(Double($0) * 0.17)) * 0.12 } : []
                        capture.context?.publishVisualization(.init(samples: samples, spectrum: [0.2, 0.6, 0.8, 0.5]))
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                }
                let host = await NativeClientPreviewSelfTests.renderHost(
                    AnyView(CapsuleView(presentationOverride: presentation).environmentObject(controller)),
                    width: Int(presentation.size.width), height: Int(presentation.size.height), dark: true)
                let file = name + ".png"
                try NativeClientPreviewSelfTests.capture(host, to: root.appendingPathComponent(file), pixelScale: 1)
                feed.cancel(); await feed.value
                let data = try Data(contentsOf: root.appendingPathComponent(file))
                let image = NSBitmapImageRep(data: data)!
                records.append(.init(file: file, width: Int(presentation.size.width), height: Int(presentation.size.height),
                    pixelWidth: image.pixelsWide, pixelHeight: image.pixelsHigh, title: presentation.title, subtitle: presentation.subtitle))
                r.eq(image.pixelsWide, Int(presentation.size.width), "capsule preview: \(name) real 1× width")
                r.eq(image.pixelsHigh, Int(presentation.size.height), "capsule preview: \(name) real 1× height")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: root.appendingPathComponent("manifest.json"))
            r.eq(records.count, fixtures.count, "capsule preview: all selected actual native states rendered")
            print("Capsule preview artifacts: \(root.path) (\(records.count) PNGs)")
        } catch { r.check(false, "capsule preview: \(error)") }
        r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "capsule preview: no prohibited effect attempts")
        r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "capsule preview: no live system effects")
    }
}
#endif
