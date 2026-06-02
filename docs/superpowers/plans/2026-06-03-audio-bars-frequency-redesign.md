# Frequency-Driven Audio Bars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the capsule's volume-driven 9-bar visualizer with a frequency-driven (FFT) ~28-bar mirrored soundwave that reacts to spectral content, styled with the brand purple→blue gradient.

**Architecture:** A pure `SpectrumMath` helper (log-binning / normalize / smooth / center-envelope) plus a `SpectrumAnalyzer` class (vDSP FFT → bands). `AudioRecorder` yields `[Float]` spectra instead of a scalar amplitude; the pipeline (`SessionContext` → `SessionController`) carries `[Float]`; `AudioVisualizer` renders 28 mirrored, envelope-weighted, gradient bars.

**Tech Stack:** Swift 6.2, Accelerate/vDSP (FFT), SwiftUI, Combine. No XCTest (CLT only) — pure logic verified via `swift run FlowType --self-test`; the FFT is verified by feeding a synthetic sine and asserting the peak bin.

**Spec:** `docs/superpowers/specs/2026-06-03-audio-bars-frequency-redesign-design.md`

**Verification commands (used throughout):**
- Build: `swift build` (expect `Build complete!`)
- Self-test: `set -o pipefail; swift run FlowType --self-test` (expect `... passed, 0 failed`, exit 0)

---

## File structure

- Create `Sources/flowtype/Services/SpectrumMath.swift` — pure functions: `centerEnvelope`, `logBin`, `normalize`, `smooth`.
- Create `Sources/flowtype/Services/SpectrumAnalyzer.swift` — `SpectrumAnalyzer` class: vDSP FFT `magnitudes` + `process` (→ smoothed bands).
- Modify `Sources/flowtype/Services/AudioRecorder.swift` — yield `[Float]` spectrum instead of `Float` amplitude.
- Modify `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift` — forward spectrum.
- Modify `Sources/flowtype/Core/Pipeline/SessionContext.swift` — `currentSpectrum` / `spectrumPublisher`.
- Modify `Sources/flowtype/Core/PipelineOrchestrator.swift` — `@Published spectrum: [Float]`.
- Modify `Sources/flowtype/UI/AudioVisualizer.swift` — new mirrored/gradient rendering.
- Modify `Sources/flowtype/Testing/SelfTest.swift` — 3 new test methods.

---

## Task 1: SpectrumMath pure helpers (TDD)

**Files:**
- Create: `Sources/flowtype/Services/SpectrumMath.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] **Step 1: Write the failing self-test**

In `Sources/flowtype/Testing/SelfTest.swift`, add this method to the `SelfTest` enum, and add `testSpectrumMath(r)` to `runAndExit()` after the existing test calls:

```swift
    static func testSpectrumMath(_ r: Reporter) {
        let env = SpectrumMath.centerEnvelope(count: 9)
        r.eq(env.count, 9, "spectrum: envelope length")
        r.check(env.first! < 0.01, "spectrum: envelope edge ~0")
        r.check(env[4] > 0.99, "spectrum: envelope center ~1")
        r.check(abs(env[1] - env[7]) < 1e-5, "spectrum: envelope symmetric")

        var mags = [Float](repeating: 0, count: 512)   // fftSize 1024 -> 512 magnitudes
        mags[64] = 10                                  // bin 64 = 64*(16000/1024) = 1000 Hz
        let bands = SpectrumMath.logBin(mags, sampleRate: 16000, fftSize: 1024,
                                        bandCount: 28, minHz: 80, maxHz: 6000)
        r.eq(bands.count, 28, "spectrum: band count")
        let maxIdx = bands.indices.max(by: { bands[$0] < bands[$1] })!
        r.check(bands[maxIdx] > 0, "spectrum: energy lands in a band")
        r.check(maxIdx > 0 && maxIdx < 27, "spectrum: 1kHz lands mid-range")

        r.eq(SpectrumMath.normalize([5, 10, 0], reference: 10), [0.5, 1.0, 0.0], "spectrum: normalize clamps 0...1")
        let up = SpectrumMath.smooth(previous: [0], target: [1], attack: 0.5, decay: 0.1)
        r.check(abs(up[0] - 0.5) < 1e-6, "spectrum: attack rate (fast rise)")
        let down = SpectrumMath.smooth(previous: [1], target: [0], attack: 0.5, decay: 0.1)
        r.check(abs(down[0] - 0.9) < 1e-6, "spectrum: decay rate (slow fall)")
    }
```

- [ ] **Step 2: Run to verify it fails (compile error — SpectrumMath doesn't exist)**

Run: `swift build`
Expected: FAIL — `cannot find 'SpectrumMath' in scope`.

- [ ] **Step 3: Create `SpectrumMath.swift`**

```swift
import Foundation

/// Pure DSP helpers for the audio visualizer (no FFT here — see SpectrumAnalyzer).
enum SpectrumMath {

    /// Raised-cosine (Hann) envelope across `count` bar positions: ~0 at the edges,
    /// 1 at the center. Used to weight bars into a center-high soundwave silhouette.
    static func centerEnvelope(count: Int) -> [Float] {
        guard count > 1 else { return count == 1 ? [1] : [] }
        return (0..<count).map { i in
            let x = Float(i) / Float(count - 1)        // 0...1
            return 0.5 - 0.5 * cos(2 * Float.pi * x)   // 0 at edges, 1 at center
        }
    }

    /// Maps an FFT magnitude spectrum (length fftSize/2) into `bandCount` log-spaced
    /// bands across [minHz, maxHz], averaging magnitudes within each band.
    static func logBin(_ magnitudes: [Float], sampleRate: Float, fftSize: Int,
                       bandCount: Int, minHz: Float, maxHz: Float) -> [Float] {
        guard bandCount > 0, magnitudes.count > 1, maxHz > minHz, minHz > 0 else {
            return [Float](repeating: 0, count: max(bandCount, 0))
        }
        let binHz = sampleRate / Float(fftSize)
        let logMin = log(minHz)
        let logMax = log(maxHz)
        var bands = [Float](repeating: 0, count: bandCount)
        var counts = [Int](repeating: 0, count: bandCount)
        for bin in 1..<magnitudes.count {              // skip DC (bin 0)
            let hz = Float(bin) * binHz
            if hz < minHz || hz > maxHz { continue }
            let t = (log(hz) - logMin) / (logMax - logMin)
            var band = Int(t * Float(bandCount))
            if band >= bandCount { band = bandCount - 1 }
            if band < 0 { band = 0 }
            bands[band] += magnitudes[bin]
            counts[band] += 1
        }
        for i in 0..<bandCount where counts[i] > 0 {
            bands[i] /= Float(counts[i])
        }
        return bands
    }

    /// Normalizes band energies to 0...1 against a reference level.
    static func normalize(_ bands: [Float], reference: Float) -> [Float] {
        let ref = Swift.max(reference, 1e-6)
        return bands.map { Swift.min(Swift.max($0, 0) / ref, 1.0) }
    }

    /// Per-band attack-fast / decay-slow smoothing toward `target`.
    static func smooth(previous: [Float], target: [Float], attack: Float, decay: Float) -> [Float] {
        guard previous.count == target.count else { return target }
        return zip(previous, target).map { prev, tgt in
            let rate = tgt > prev ? attack : decay
            return prev + (tgt - prev) * rate
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/flowtype/Services/SpectrumMath.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat: add SpectrumMath pure helpers (envelope/logBin/normalize/smooth)"
```

---

## Task 2: SpectrumAnalyzer FFT magnitudes (TDD with synthetic sine)

**Files:**
- Create: `Sources/flowtype/Services/SpectrumAnalyzer.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] **Step 1: Write the failing self-test**

Add to the `SelfTest` enum and call `testFFTPeak(r)` in `runAndExit()`:

```swift
    static func testFFTPeak(_ r: Reporter) {
        let analyzer = SpectrumAnalyzer()
        let fs: Float = 16000
        let freq: Float = 1000
        let n = 1024
        let samples = (0..<n).map { sin(2 * Float.pi * freq * Float($0) / fs) }
        let mags = analyzer.magnitudes(samples)
        r.eq(mags.count, 512, "spectrum: FFT half-spectrum length")
        let peak = mags.indices.max(by: { mags[$0] < mags[$1] })!
        let expected = Int(freq / (fs / Float(n)))     // 1000 / 15.625 = 64
        r.check(abs(peak - expected) <= 2, "spectrum: FFT peak at ~1kHz bin (got \(peak), want ~\(expected))")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build`
Expected: FAIL — `cannot find 'SpectrumAnalyzer' in scope`.

- [ ] **Step 3: Create `SpectrumAnalyzer.swift` (magnitudes only for now)**

```swift
import Accelerate

/// Turns 16 kHz mono Float32 audio buffers into smoothed, normalized frequency-band
/// energies for the capsule visualizer. Holds the FFT setup + smoothing state, so a
/// fresh instance should be used per recording session.
final class SpectrumAnalyzer {
    let bandCount: Int
    let fftSize: Int
    let sampleRate: Float
    private let minHz: Float
    private let maxHz: Float
    private let attack: Float
    private let decay: Float

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let hann: [Float]
    private var smoothed: [Float]
    private var rollingMax: Float = 1e-6

    init(bandCount: Int = 28, fftSize: Int = 1024, sampleRate: Float = 16000,
         minHz: Float = 80, maxHz: Float = 6000, attack: Float = 0.6, decay: Float = 0.18) {
        self.bandCount = bandCount
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.minHz = minHz
        self.maxHz = maxHz
        self.attack = attack
        self.decay = decay
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        self.hann = window
        self.smoothed = [Float](repeating: 0, count: bandCount)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Hann-windowed magnitude spectrum (length fftSize/2). Input is zero-padded or
    /// truncated to `fftSize`.
    func magnitudes(_ samples: [Float]) -> [Float] {
        let halfN = fftSize / 2
        var frame = [Float](repeating: 0, count: fftSize)
        let n = Swift.min(samples.count, fftSize)
        for i in 0..<n { frame[i] = samples[i] }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: DSPComplex.self).baseAddress {
                        vDSP_ctoz(base, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))
            }
        }
        return mags
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`. (If the FFT peak assertion fails, the vDSP packing is off — fix `magnitudes` until the 1 kHz sine peaks at bin ~64; do not change the test.)

- [ ] **Step 5: Commit**

```bash
git add Sources/flowtype/Services/SpectrumAnalyzer.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat: add SpectrumAnalyzer FFT magnitudes (vDSP), verified by sine peak test"
```

---

## Task 3: SpectrumAnalyzer.process() integration (TDD)

**Files:**
- Modify: `Sources/flowtype/Services/SpectrumAnalyzer.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] **Step 1: Write the failing self-test**

Add to `SelfTest` and call `testSpectrumProcess(r)` in `runAndExit()`:

```swift
    static func testSpectrumProcess(_ r: Reporter) {
        let analyzer = SpectrumAnalyzer()
        let fs: Float = 16000
        let freq: Float = 1000
        let samples = (0..<1024).map { sin(2 * Float.pi * freq * Float($0) / fs) }
        var bands = [Float]()
        for _ in 0..<10 { bands = analyzer.process(samples) }   // let smoothing settle
        r.eq(bands.count, 28, "spectrum: process band count")
        r.check(bands.allSatisfy { $0 >= 0 && $0 <= 1.0001 }, "spectrum: process bands in 0...1")
        let maxIdx = bands.indices.max(by: { bands[$0] < bands[$1] })!
        r.check(bands[maxIdx] > 0.5, "spectrum: dominant band strong after settling")

        let silence = [Float](repeating: 0, count: 1024)
        var quiet = [Float]()
        for _ in 0..<30 { quiet = analyzer.process(silence) }
        r.check((quiet.max() ?? 1) < 0.2, "spectrum: silence decays toward 0")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build`
Expected: FAIL — `value of type 'SpectrumAnalyzer' has no member 'process'`.

- [ ] **Step 3: Add `process` and `reset` to `SpectrumAnalyzer`**

Add these methods inside the `SpectrumAnalyzer` class (after `magnitudes`):

```swift
    /// Process one audio buffer → smoothed, normalized band energies (0...1, length bandCount).
    func process(_ samples: [Float]) -> [Float] {
        let mags = magnitudes(samples)
        let bands = SpectrumMath.logBin(mags, sampleRate: sampleRate, fftSize: fftSize,
                                        bandCount: bandCount, minHz: minHz, maxHz: maxHz)
        let peak = bands.max() ?? 0
        rollingMax = Swift.max(peak, rollingMax * 0.995)   // adaptive reference, slow decay
        let normalized = SpectrumMath.normalize(bands, reference: rollingMax)
        smoothed = SpectrumMath.smooth(previous: smoothed, target: normalized, attack: attack, decay: decay)
        return smoothed
    }

    /// Resets smoothing state between sessions.
    func reset() {
        smoothed = [Float](repeating: 0, count: bandCount)
        rollingMax = 1e-6
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/flowtype/Services/SpectrumAnalyzer.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat: SpectrumAnalyzer.process — log-binned, normalized, smoothed bands"
```

---

## Task 4: Swap the amplitude pipeline to spectrum + new visualizer

Change the scalar `amplitude: Float` pipeline to `spectrum: [Float]` end-to-end, and replace `AudioVisualizer` with the mirrored/gradient rendering. This is one commit because the type change cascades and the build must be green at the commit.

**Files:**
- Modify: `AudioRecorder.swift`, `RecordingStage.swift`, `SessionContext.swift`, `PipelineOrchestrator.swift`, `AudioVisualizer.swift`

- [ ] **Step 1: AudioRecorder — produce a spectrum stream**

In `Sources/flowtype/Services/AudioRecorder.swift`:

(a) `RecordingOutput`:
```swift
struct RecordingOutput: @unchecked Sendable {
    /// Per-buffer frequency-band energies (0...1) for the visualizer.
    let spectrum: AsyncStream<[Float]>
}
```

(b) The continuation property — replace
```swift
    private nonisolated(unsafe) var amplitudeContinuation: AsyncStream<Float>.Continuation?
```
with
```swift
    private nonisolated(unsafe) var spectrumContinuation: AsyncStream<[Float]>.Continuation?
```

(c) In `startRecording`, replace the stream creation line
```swift
        let amplitudeStream = AsyncStream<Float> { continuation in
            self.amplitudeContinuation = continuation
```
with (create a fresh analyzer captured by the tap closure):
```swift
        let analyzer = SpectrumAnalyzer()
        let spectrumStream = AsyncStream<[Float]> { continuation in
            self.spectrumContinuation = continuation
```

(d) Replace the average-amplitude block (the `// Yield average amplitude for VU meter` lines that compute `sum`/`avg` and call `self.amplitudeContinuation?.yield(avg)`) with:
```swift
                    // Yield the frequency spectrum for the visualizer.
                    let spectrum = analyzer.process(samplesArray)
                    self.spectrumContinuation?.yield(spectrum)
```
(`samplesArray` already exists in that scope from the raw-sample accumulation above.)

(e) The heartbeat-freeze finish — replace `self.amplitudeContinuation?.finish()` with `self.spectrumContinuation?.finish()`.

(f) The return — replace `return RecordingOutput(amplitude: amplitudeStream)` with `return RecordingOutput(spectrum: spectrumStream)`.

(g) In `stopRecording`, replace `amplitudeContinuation?.finish()` / `amplitudeContinuation = nil` with `spectrumContinuation?.finish()` / `spectrumContinuation = nil`.

- [ ] **Step 2: RecordingStage — forward the spectrum**

In `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift`, replace the amplitude-consuming loop:
```swift
            for await amp in output.amplitude {
                try Task.checkCancellation()
                await MainActor.run {
                    context.currentAmplitude = amp
                    context.amplitudePublisher.send(amp)
                }
            }
```
with:
```swift
            for await spectrum in output.spectrum {
                try Task.checkCancellation()
                await MainActor.run {
                    context.currentSpectrum = spectrum
                    context.spectrumPublisher.send(spectrum)
                }
            }
```
(Leave the surrounding log lines; if a log says "amplitude stream", you may reword to "spectrum stream" but it is not required.)

- [ ] **Step 3: SessionContext — spectrum fields**

In `Sources/flowtype/Core/Pipeline/SessionContext.swift`, replace:
```swift
    var currentAmplitude: Float = 0.0
```
with
```swift
    var currentSpectrum: [Float] = []
```
and replace:
```swift
    let amplitudePublisher = PassthroughSubject<Float, Never>()
```
with
```swift
    let spectrumPublisher = PassthroughSubject<[Float], Never>()
```

- [ ] **Step 4: PipelineOrchestrator — @Published spectrum**

In `Sources/flowtype/Core/PipelineOrchestrator.swift`:
- Replace `@Published private(set) var amplitude: Float = 0.0` with `@Published private(set) var spectrum: [Float] = []`.
- Delete the `amplitudeUpdateThreshold` line and its doc comment.
- Replace `private var amplitudeCancellable: AnyCancellable?` with `private var spectrumCancellable: AnyCancellable?`.
- Replace the subscribe block:
```swift
        // Subscribe to real-time amplitude/preview publishers (avoids 1Hz timer polling)
        amplitudeCancellable = context.amplitudePublisher
            .sink { [weak self] amp in
                guard let self else { return }
                if abs(self.amplitude - amp) > self.amplitudeUpdateThreshold {
                    self.amplitude = amp
                }
            }
```
with:
```swift
        // Subscribe to real-time spectrum/preview publishers (avoids 1Hz timer polling)
        spectrumCancellable = context.spectrumPublisher
            .sink { [weak self] spec in
                self?.spectrum = spec
            }
```
- Replace the reset pair `amplitudeCancellable?.cancel()` / `amplitudeCancellable = nil` with `spectrumCancellable?.cancel()` / `spectrumCancellable = nil`.
- Replace BOTH `amplitude = 0.0` reset lines (there are two) with `spectrum = []`.

- [ ] **Step 5: AudioVisualizer — mirrored gradient bars**

Replace the ENTIRE contents of `Sources/flowtype/UI/AudioVisualizer.swift` with:
```swift
import SwiftUI

/// Frequency-driven mirrored soundwave for the recording capsule.
struct AudioVisualizer: View {
    @EnvironmentObject var session: SessionController

    private static let barCount = 28
    private static let envelope = SpectrumMath.centerEnvelope(count: barCount)
    private let maxBarHeight: CGFloat = 24

    var body: some View {
        let active = session.sessionState.isRecordingIndicator
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                let level = barLevel(i, active: active)
                Capsule()
                    .fill(barColor(i, level: level))
                    .frame(width: 3, height: max(2, level * maxBarHeight))
                    .frame(maxHeight: .infinity, alignment: .center)   // grow up+down from center
            }
        }
        .frame(width: 112, height: maxBarHeight + 2)
        .animation(.easeOut(duration: 0.09), value: session.spectrum)  // tween between updates
    }

    /// Envelope-weighted band energy; a calm resting line when not recording.
    private func barLevel(_ i: Int, active: Bool) -> CGFloat {
        let env = CGFloat(Self.envelope[i])
        guard active else { return env * 0.06 }
        let band = i < session.spectrum.count ? CGFloat(session.spectrum[i]) : 0
        return env * max(band, 0.05)
    }

    /// Brand purple→blue gradient across bars; brighter where there's energy.
    private func barColor(_ i: Int, level: CGFloat) -> Color {
        let t = Double(i) / Double(Self.barCount - 1)
        let red = 0.55 + (0.30 - 0.55) * t
        let green = 0.35 + (0.65 - 0.35) * t
        let blue = 1.0
        let brightness = 0.45 + 0.55 * Double(min(level / 0.6, 1.0))
        return Color(red: red, green: green, blue: blue).opacity(brightness)
    }
}
```

- [ ] **Step 6: Build + self-test**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`, exit 0.
If the build complains about a leftover `amplitude` reference, find it: `grep -rn "amplitude\|amplitudePublisher\|currentAmplitude\|amplitudeContinuation" Sources/` and convert it (only `AudioRecorder` internal naming or a log string should remain, and only if intentional).

- [ ] **Step 7: Commit**

```bash
git add Sources/flowtype/Services/AudioRecorder.swift Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift Sources/flowtype/Core/Pipeline/SessionContext.swift Sources/flowtype/Core/PipelineOrchestrator.swift Sources/flowtype/UI/AudioVisualizer.swift
git commit -m "feat: drive capsule bars from frequency spectrum (mirrored, brand gradient)"
```

---

## Task 5: Manual verification (real recording)

Self-tests cover the pure DSP. The live look needs a real session (no Xcode here, so build the app or `swift run` with `mlx.metallib` next to the debug binary).

- [ ] **Step 1: Build a runnable app**

Run: `./scripts/build-app.sh && open build/FlowType.app` (grant Microphone/Accessibility on first run).

- [ ] **Step 2: Bars react to speech content**

Double-tap to record, then speak varied sounds (hum a low tone, then an "sss", then normal speech).
Expected: the ~28 mirrored bars react differently to different sounds (low tone → left/low bands; "sss" → right/high bands), not all moving together. The silhouette stays center-high (envelope). Color runs purple→blue.

- [ ] **Step 3: Idle / silence**

While recording, stay silent for a moment.
Expected: bars settle to a low calm line (not rigidly flat, not jittery).

- [ ] **Step 4: Tune if needed**

Per spec §9, if the feel is off, adjust constants and re-verify (then commit the tweak):
- too coarse/steppy → lower `attack`/raise smoothing, or shorten the `.animation` duration.
- bars look dead / clipped → adjust `minHz`/`maxHz` (try 100–5000), the rollingMax decay (0.995), or `maxBarHeight`.
- too many/few bars → change `barCount` (24–32) in both `AudioVisualizer` and the `SpectrumAnalyzer()` default.

```bash
git add -A && git commit -m "fix: tune audio-bar feel from manual verification"
```

---

## Self-review (completed by author)

- **Spec coverage:** §3 FFT/bands → Tasks 1–3 (`SpectrumMath` + `SpectrumAnalyzer`). §4 data-flow swap → Task 4 steps 1–4. §5 visual (mirrored, envelope, gradient) → Task 4 step 5. §6 animation/idle → Task 4 step 5 (`.animation(value:)` + resting line) + Task 5 tuning. §7 perf → inherent (vDSP). All covered.
- **Placeholder scan:** none — every code step has complete code; every run step has command + expected output. The "tune" step (Task 5.4) is verification tuning, not a code placeholder.
- **Type consistency:** `SpectrumMath` (`centerEnvelope`/`logBin`/`normalize`/`smooth`), `SpectrumAnalyzer` (`magnitudes`/`process`/`reset`, init defaults bandCount 28 / fftSize 1024 / sampleRate 16000), `RecordingOutput.spectrum: AsyncStream<[Float]>`, `SessionContext.currentSpectrum`/`spectrumPublisher`, `SessionController.spectrum`, `AudioVisualizer` reads `session.spectrum` — consistent across tasks.
