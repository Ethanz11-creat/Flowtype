import Foundation
import Combine

enum CapsuleWaveformSelfTests {
    static func signal(_ amplitude: Float, at time: Double = 0) -> AudioVisualizationFrame {
        let samples = (0..<1024).map { amplitude * sin(Float($0) * 2 * .pi * 440 / 16_000) }
        return AudioVisualizationFrame(samples: samples, spectrum: Array(repeating: 1, count: 10), timestamp: time)
    }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        let quiet = signal(0.015), loud = signal(0.3)
        r.check(abs(quiet.rms - 0.015 / sqrt(2)) < 0.0001, "waveform: actual quiet sine PCM RMS")
        r.check(abs(loud.rms - 0.3 / sqrt(2)) < 0.001, "waveform: actual loud sine PCM RMS")
        r.check(loud.level > quiet.level + 0.25, "waveform: absolute quiet/loud separation despite identical normalized FFT")
        for samples: [Float] in [[], [0, 0], [.nan, .infinity, -.infinity]] {
            let frame = AudioVisualizationFrame(samples: samples, spectrum: [.nan, .infinity, -1, 3], timestamp: 0)
            r.eq(frame.rms, 0, "waveform: empty/silent/nonfinite PCM is silent")
            r.check(frame.level.isFinite && frame.level == 0, "waveform: invalid PCM level is finite rest")
        }
        var pulse = DiffusionWaveform()
        pulse.accept(signal(0.3))
        pulse.accept(signal(0, at: 0.04))
        let early = pulse.heights(at: 0.025), later = pulse.heights(at: 0.18)
        r.eq(early.count, 10, "waveform: ten bars")
        r.check(early[4] > 3 && early[0] == 2, "waveform: center responds before outer bars")
        r.check(later[0] > early[0] + 0.2, "waveform: short pulse diffuses outward after input stops")
        r.check(later != later.reversed().map { $0 }, "waveform: stable slight asymmetry")
        r.eq(pulse.heights(at: 3), Array(repeating: 2, count: 10), "waveform: silence settles to exact rest")
        var stale = DiffusionWaveform(); stale.accept(loud)
        r.eq(stale.heights(at: 3), Array(repeating: 2, count: 10), "waveform: missing callbacks settle to exact rest")
        stale.reset()
        r.eq(stale.heights(at: 0.1), Array(repeating: 2, count: 10), "waveform: reset clears diffusion history")
        var soft = DiffusionWaveform(), strong = DiffusionWaveform()
        for i in 0..<100 {
            soft.accept(signal(0.015, at: Double(i) * 0.05))
            strong.accept(signal(0.3, at: Double(i) * 0.05))
        }
        let softHeights = soft.heights(at: 4.98), strongHeights = strong.heights(at: 4.98)
        r.check(strongHeights[4] > softHeights[4] + 4, "waveform: sustained quiet stays smaller than sustained loud")
        r.check(strongHeights.allSatisfy { $0.isFinite && (2...18).contains($0) }, "waveform: bounded finite output")
        var fast = DiffusionWaveform(), slow = DiffusionWaveform()
        for i in 0..<10 {
            let frame = signal(i.isMultiple(of: 3) ? 0 : 0.2, at: Double(i) * 0.05)
            fast.accept(frame); slow.accept(frame)
            for tick in 0..<3 { _ = fast.heights(at: Double(i) * 0.05 + Double(tick) / 60) }
            _ = slow.heights(at: Double(i) * 0.05)
        }
        r.eq(fast.heights(at: 0.52), slow.heights(at: 0.52), "waveform: rendering intervals do not change elapsed-time motion")
        var reduced = DiffusionWaveform(); reduced.accept(loud)
        let reducedHeights = reduced.heights(at: 0.025, reduceMotion: true)
        r.check(reducedHeights.allSatisfy { $0 > 2 && $0 <= 18 }, "waveform: Reduce Motion responds directly without travelling delay")
        r.check(reduced.heights(at: 0.2, reduceMotion: true)[4] < stalePeak(loud), "waveform: Reduce Motion restrains amplitude")
        r.eq(reduced.heights(at: 3, reduceMotion: true), Array(repeating: 2, count: 10), "waveform: Reduce Motion stale signal rests")
        var silent = DiffusionWaveform(); silent.accept(.silence)
        r.eq(silent.heights(at: 0.1), Array(repeating: 2, count: 10), "waveform: no synthetic motion under silence")
        r.eq(silent.heights(at: .nan), Array(repeating: 2, count: 10), "waveform: nonfinite clock is bounded rest")
        let malformed = AudioVisualizationFrame(samples: [.greatestFiniteMagnitude], spectrum: [.nan, .infinity, -1, 3], timestamp: .nan)
        r.eq(malformed.spectrum, [0, 0, 0, 1], "waveform: malformed frequency detail sanitized")
        silent.accept(malformed)
        r.check(silent.heights(at: 0.1).allSatisfy { $0.isFinite && (2...18).contains($0) }, "waveform: malformed frame stays finite and bounded")
        await streams(r)
        await lifecycle(r)
    }

    private static func stalePeak(_ frame: AudioVisualizationFrame) -> Double {
        var motion = DiffusionWaveform(); motion.accept(frame)
        return motion.heights(at: 0.2)[4]
    }

    static func streams(_ r: SelfTest.Reporter) async {
        let legacy = AsyncStream<[Float]>.makeStream()
        legacy.continuation.yield([0.2, 0.7]); legacy.continuation.finish()
        var adapted = RecordingOutput(spectrum: legacy.stream).visualizationFrames.makeAsyncIterator()
        let frame = await adapted.next()
        r.eq(frame?.spectrum, [0.2, 0.7], "waveform: legacy fixture spectrum remains compatible")
        r.eq(frame?.rms, 0, "waveform: legacy normalized spectrum cannot invent volume")
        r.check(await adapted.next() == nil, "waveform: legacy finish propagates")
        let compatible = AsyncStream<[Float]>.makeStream()
        compatible.continuation.yield([0.4]); compatible.continuation.finish()
        var spectra = RecordingOutput(spectrum: compatible.stream).spectrum.makeAsyncIterator()
        r.eq(await spectra.next(), [0.4], "waveform: old spectrum consumer remains source compatible")
        let live = RecordingOutput.makeVisualizationStream()
        live.continuation.yield(signal(0.02)); live.continuation.yield(signal(0.3, at: 0.1))
        live.continuation.finish()
        var frames = RecordingOutput(visualizationFrames: live.stream).visualizationFrames.makeAsyncIterator()
        r.eq(await frames.next(), signal(0.3, at: 0.1), "waveform: bounded queue keeps newest whole frame")
        r.check(await frames.next() == nil, "waveform: finish drains newest then terminates")
        let cancelled = RecordingOutput.makeVisualizationStream()
        let consumer = Task { () -> AudioVisualizationFrame? in
            var iterator = RecordingOutput(visualizationFrames: cancelled.stream).visualizationFrames.makeAsyncIterator()
            return await iterator.next()
        }
        consumer.cancel()
        r.check(await consumer.value == nil, "waveform: cancellation releases suspended frame consumer")
        if case .terminated = cancelled.continuation.yield(signal(0.3)) {
            r.check(true, "waveform: cancellation rejects late yields")
        } else { r.check(false, "waveform: cancellation rejects late yields") }
    }

    private struct Stage: PipelineStage {
        let name = "Synthetic waveform recording"
        let run: @MainActor @Sendable (SessionContext) async -> StageResult
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult { await run(context) }
    }

    @MainActor private final class Capture {
        var contexts: [SessionContext] = []
        var continuation: CheckedContinuation<Void, Never>?
        func run(_ context: SessionContext) async -> StageResult {
            contexts.append(context)
            context.markReady()
            await withCheckedContinuation { continuation = $0 }
            return .complete
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor private static func lifecycle(_ r: SelfTest.Reporter) async {
        let suite = "FlowTypeWaveform.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let resources = SessionResourceCoordinator(), capture = Capture()
        let controller = SessionController(pipeline: [Stage(run: { await capture.run($0) })], observers: [],
            effects: .init(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in }),
            recoveryEffects: .init(openAccessibilitySettings: {}, openMicrophoneSettings: {}, openSpeechRecognitionSettings: {},
                openASRSettings: {}, openHistory: {}, copyText: { _ in }),
            configurationStore: ConfigurationStore(defaults: defaults), refreshReadiness: { .ready }, readinessLevel: { .ready },
            purpose: .trial, resources: resources)
        controller.startRecording()
        await wait { capture.contexts.count == 1 }
        guard let old = capture.contexts.first else { r.check(false, "waveform: synthetic recording started"); return }
        let loud = signal(0.3, at: 1)
        old.publishVisualization(loud)
        r.eq(controller.visualizationFrame, loud, "waveform: owned audio frame reaches controller")
        r.eq(controller.spectrum, loud.spectrum, "waveform: legacy controller spectrum stays synchronized")
        controller.endRecording()
        r.eq(controller.visualizationFrame, .silence, "waveform: stop clears published visual energy")
        old.publishVisualization(loud)
        r.eq(controller.visualizationFrame, .silence, "waveform: queued audio after stop cannot restart visualizer")
        controller.cancel(); capture.release()
        await wait { resources.owner == nil }
        r.eq(controller.visualizationFrame, .silence, "waveform: cancellation resets published frame")
        controller.startRecording()
        await wait { capture.contexts.count == 2 }
        guard capture.contexts.count == 2 else { r.check(false, "waveform: replacement started"); return }
        let current = capture.contexts[1]
        r.eq(controller.visualizationFrame, .silence, "waveform: new recording starts at rest")
        old.publishVisualization(loud)
        old.visualizationPublisher.send(loud) // A delayed pre-cancellation publisher delivery.
        r.eq(controller.visualizationFrame, .silence, "waveform: cancelled old callback cannot animate replacement")
        r.eq(old.currentVisualizationFrame, .silence, "waveform: cancelled context rejects late PCM publication")
        let quiet = signal(0.02, at: 2)
        current.publishVisualization(quiet)
        r.eq(controller.visualizationFrame, quiet, "waveform: replacement accepts its own audio")
        var armed = true
        let publication = controller.objectWillChange.sink {
            guard armed else { return }
            armed = false
            controller.cancel()
        }
        current.publishVisualization(loud)
        r.eq(controller.visualizationFrame, .silence, "waveform: synchronous publication cancellation cannot restore old energy")
        publication.cancel()
        controller.cancel(); capture.release()
        await wait { resources.owner == nil }
        r.eq(controller.visualizationFrame, .silence, "waveform: replacement cancellation resets waveform")
    }
}
