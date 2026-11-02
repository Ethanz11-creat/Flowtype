import Foundation

enum M3SpeechPreflightSelfTests {
    static func pure(_ r: SelfTest.Reporter) {
        do {
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 80000)),
                 .clearlySilent, "five-second digital silence")
            r.eq(try SpeechPreflight.analyze(samples: []), .emptyCapture, "no captured audio")
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 800)),
                 .indeterminate(.tooShort), "50ms never proves silence")
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1600), sampleRate: 48000),
                 .indeterminate(.unsupportedSampleRate), "wrong rate is not silence")
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1599)),
                 .indeterminate(.tooShort), "one sample below 100ms never proves silence")
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1600)),
                 .clearlySilent, "100ms permits silence")
            r.eq(try SpeechPreflight.analyze(samples: [], sampleRate: 0),
                 .emptyCapture, "empty capture is independent of rate")
            for rate in [0, -16000, 8000, 44100] {
                r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1600), sampleRate: rate),
                     .indeterminate(.unsupportedSampleRate), "unsupported rate \(rate) never proves silence")
            }
            // Constant frames isolate RMS; isolated impulses isolate peak.
            let rms: Float = 0.0003
            for (level, expected): (Float, SpeechPreflightDecision) in [
                (rms.nextDown, .clearlySilent), (rms, .clearlySilent), (rms.nextUp, .possiblySpeech)
            ] {
                r.eq(try SpeechPreflight.analyze(samples: Array(repeating: level, count: 1600)),
                     expected, "Float32 RMS boundary \(level)")
            }
            let peak: Float = 0.001
            for (level, expected): (Float, SpeechPreflightDecision) in [
                (peak.nextDown, .clearlySilent), (peak, .clearlySilent), (peak.nextUp, .possiblySpeech),
                (-peak, .clearlySilent), (-peak.nextUp, .possiblySpeech)
            ] {
                for index in [0, 1599] {
                    var samples = Array(repeating: Float(0), count: 1600)
                    samples[index] = level
                    r.eq(try SpeechPreflight.analyze(samples: samples), expected,
                         "Float32 peak boundary \(level) at \(index)")
                }
            }
            // Every partial-frame length must be scanned and use its own denominator.
            for tail in 1...319 {
                var samples = Array(repeating: Float(0), count: 1600 + tail)
                samples[samples.count - 1] = Float(0.001).nextUp
                r.eq(try SpeechPreflight.analyze(samples: samples), .possiblySpeech,
                     "tail length \(tail) retains final peak")
                samples = Array(repeating: Float(0), count: 1600) + Array(repeating: rms.nextUp, count: tail)
                r.eq(try SpeechPreflight.analyze(samples: samples), .possiblySpeech,
                     "tail length \(tail) retains tail RMS")
            }
            let sine = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 200 / 16000)) * 0.0002 }
            r.eq(try SpeechPreflight.analyze(samples: sine), .clearlySilent,
                 "low-amplitude synthetic sine lies below candidate energy thresholds")
            r.eq(try SpeechPreflight.analyze(samples: sine.map { $0 * 4 }), .possiblySpeech,
                 "synthetic sine above RMS but below peak is retained")
            var delayed = Array(repeating: Float(0), count: 7 * 16000 + 17)
            delayed[6 * 16000 + 1] = 0.01
            r.eq(try SpeechPreflight.analyze(samples: delayed), .possiblySpeech,
                 "signal after six seconds is retained")
            var mixed = Array(repeating: Float(0), count: 16000)
            for i in 320..<640 { mixed[i] = 0.0005 }
            r.eq(try SpeechPreflight.analyze(samples: mixed), .possiblySpeech,
                 "one energetic frame is not diluted by surrounding silence")
            for (level, expected): (Float, SpeechPreflightDecision) in [
                (0.0004, .clearlySilent), (0.0005, .possiblySpeech)
            ] {
                let mixedFrame = Array(repeating: Float(0), count: 160) + Array(repeating: level, count: 160)
                r.eq(try SpeechPreflight.analyze(samples: mixedFrame + Array(repeating: 0, count: 1280)),
                     expected, "mixed frame RMS retains both silent and signal samples at \(level)")
            }
            r.eq(try SpeechPreflight.analyze(samples: [0.5]), .indeterminate(.tooShort),
                 "valid short signal stays indeterminate")
            for invalid: Float in [.nan, .infinity, -.infinity, 1.0001, -1.0001] {
                for index in [0, 319, 1600] {
                    var samples = Array(repeating: Float(0), count: 1601)
                    samples[index] = invalid
                    r.eq(try SpeechPreflight.analyze(samples: samples), .indeterminate(.invalidSamples),
                         "invalid sample at \(index) never proves silence")
                    samples[index == 0 ? 1 : 0] = 0.5
                    r.eq(try SpeechPreflight.analyze(samples: samples), .indeterminate(.invalidSamples),
                         "sound cannot hide invalid sample at \(index)")
                }
                r.eq(try SpeechPreflight.analyze(samples: [invalid]), .indeterminate(.invalidSamples),
                     "short invalid capture is still invalid")
            }
            r.eq(try SpeechPreflight.analyze(samples: [1, -1] + Array(repeating: 0, count: 1598)),
                 .possiblySpeech, "normalized inclusive endpoints are valid")
        } catch {
            r.check(false, "M3 preflight pure: unexpected error \(error)")
        }
    }

    private enum ProbeError: Error { case synthetic }

    /// The analyzer deliberately blocks synchronously. A timeout makes an actor
    /// regression fail instead of hanging the entire self-test process.
    private final class Barrier: @unchecked Sendable {
        struct State {
            var entered = false
            var onMainThread = false
            var forwardedInput = false
            var timedOut = false
            var cancelled = false
            var exited = false
        }
        private let lock = NSLock()
        private var state = State()
        let release = DispatchSemaphore(value: 0)
        var snapshot: State { lock.withLock { state } }

        func analyze(_ samples: [Float], _ rate: Int, cooperative: Bool, throwsError: Bool) throws -> SpeechPreflightDecision {
            lock.withLock {
                state.entered = true
                state.onMainThread = Thread.isMainThread
                state.forwardedInput = samples == [0.25, -0.5] && rate == 12345
            }
            let timedOut = release.wait(timeout: .now() + 2) != .success
            defer {
                lock.withLock {
                    state.timedOut = timedOut
                    state.cancelled = Task.isCancelled
                    state.exited = true
                }
            }
            if cooperative { try Task.checkCancellation() }
            if throwsError { throw ProbeError.synthetic }
            return .possiblySpeech
        }
    }

    @MainActor static func background(_ r: SelfTest.Reporter) async {
        do {
            r.eq(try await SpeechPreflight.evaluate(samples: Array(repeating: 0, count: 1600)),
                 .clearlySilent, "production default analyzer recognizes silence")
            r.eq(try await SpeechPreflight.evaluate(samples: [0.5] + Array(repeating: 0, count: 1599)),
                 .possiblySpeech, "production default analyzer retains raw signal")
            r.eq(try await SpeechPreflight.evaluate(samples: [0.5] + Array(repeating: 0, count: 1600) + [.nan]),
                 .indeterminate(.invalidSamples), "production default analyzer validates tail after sound")
        } catch { r.check(false, "production default analyzer threw \(error)") }

        for mode in ["success", "cancel-return", "cancel-cooperative", "error"] {
            let barrier = Barrier()
            var completed = false
            let task = Task { @MainActor () -> Result<SpeechPreflightDecision, Error> in
                defer { completed = true }
                do {
                    return .success(try await SpeechPreflight.evaluate(samples: [0.25, -0.5], sampleRate: 12345,
                        using: { try barrier.analyze($0, $1, cooperative: mode == "cancel-cooperative", throwsError: mode == "error") }))
                } catch { return .failure(error) }
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while !barrier.snapshot.entered && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            r.check(barrier.snapshot.entered, "\(mode): synchronous analyzer entered")
            r.check(!barrier.snapshot.onMainThread, "\(mode): real evaluate runs analyzer off main thread")
            var heartbeat = false
            await Task { @MainActor in heartbeat = true }.value
            r.check(heartbeat && !barrier.snapshot.exited,
                    "\(mode): MainActor heartbeat runs while synchronous analyzer is blocked")
            let cancelling = mode.hasPrefix("cancel")
            if cancelling {
                task.cancel()
                for _ in 0..<10 { await Task.yield() }
                r.check(!completed, "\(mode): cancellation waits for synchronous worker exit")
            }
            barrier.release.signal()
            let result = await task.value
            let state = barrier.snapshot
            r.check(state.forwardedInput, "\(mode): synchronous seam receives unchanged samples and rate")
            r.check(state.exited && !state.timedOut, "\(mode): worker exits after MainActor releases barrier")
            r.eq(state.cancelled, cancelling, "\(mode): cancellation propagates to detached worker")
            switch result {
            case .success(let decision):
                r.check(!cancelling && mode == "success", "\(mode): cancelled or throwing analyzer cannot publish success")
                r.eq(decision, .possiblySpeech, "\(mode): evaluate preserves analyzer decision")
            case .failure(let error):
                if cancelling { r.check(error is CancellationError, "\(mode): wrapper returns CancellationError") }
                else { r.check(error is ProbeError && mode == "error", "\(mode): wrapper preserves analyzer error") }
            }
        }

        // Exercise production analyze itself, with no analyzer seam. The scan is
        // much longer than the cancellation delay in the debug self-test build.
        let longPCM = Array(repeating: Float(0), count: 180 * 16000)
        let realScan = Task { try await SpeechPreflight.evaluate(samples: longPCM) }
        try? await Task.sleep(for: .milliseconds(2))
        realScan.cancel()
        do {
            _ = try await realScan.value
            r.check(false, "production long-PCM scan must observe cancellation")
        } catch { r.check(error is CancellationError, "production long-PCM scan cooperatively cancels") }

        let cancelledBeforeStart = Task { try await SpeechPreflight.evaluate(samples: []) }
        cancelledBeforeStart.cancel()
        do {
            _ = try await cancelledBeforeStart.value
            r.check(false, "pre-cancelled evaluate cannot return emptyCapture")
        } catch { r.check(error is CancellationError, "pre-cancelled evaluate preserves cancellation") }
    }

    /// Opt-in measurement only: never allocate 30 minutes of PCM in routine suites.
    @MainActor static func benchmark(_ r: SelfTest.Reporter) async {
        let samples = Array(repeating: Float(0), count: 30 * 60 * 16000)
        print("M3 benchmark: synthetic zero PCM, \(samples.count) Float32 samples, 16000 Hz, 30 minutes")
        print("M3 benchmark: logical CPUs=\(ProcessInfo.processInfo.processorCount), physicalMemory=\(ProcessInfo.processInfo.physicalMemory) bytes")
        let clock = ContinuousClock()
        do {
            let analyzeStart = clock.now
            let analyzed = try SpeechPreflight.analyze(samples: samples)
            print("M3 benchmark: production analyze elapsed=\(analyzeStart.duration(to: clock.now)) decision=\(analyzed)")
            r.eq(analyzed, .clearlySilent, "30-minute production analyze result")
            let evaluateStart = clock.now
            let evaluated = try await SpeechPreflight.evaluate(samples: samples)
            print("M3 benchmark: production evaluate elapsed=\(evaluateStart.duration(to: clock.now)) decision=\(evaluated)")
            r.eq(evaluated, .clearlySilent, "30-minute production evaluate result")
        } catch { r.check(false, "30-minute production benchmark threw \(error)") }

        let scanStart = clock.now
        let task = Task { try await SpeechPreflight.evaluate(samples: samples) }
        try? await Task.sleep(for: .milliseconds(2))
        let cancelStart = clock.now
        task.cancel()
        do {
            _ = try await task.value
            r.check(false, "30-minute production scan must cancel")
        } catch {
            print("M3 benchmark: cancellation requested after=\(scanStart.duration(to: cancelStart)); request-to-worker-exit=\(cancelStart.duration(to: clock.now)); result=\(error)")
            r.check(error is CancellationError, "30-minute production cancellation result")
        }
    }
}
