# Design: Frequency-Driven Audio Bars (Mirrored Soundwave)

**Date:** 2026-06-03
**Status:** Approved (design), pending implementation plan
**Scope:** The recording capsule's audio visualizer only. (Brand-visual rollout to all windows is a separate, queued spec.)

## 1. Goal

Replace the capsule's volume-driven 9-bar visualizer with a **frequency-driven, ~28-bar
mirrored soundwave** that reacts to *what* the user says (spectral content), not just *how
loud*. The result should feel like Typeless/Siri: a stylized, smoothed wave — mid-high,
edges-low — that flows elegantly and varies with speech without looking mechanical.

## 2. Current behavior

- `AudioRecorder`, per converted 16 kHz mono buffer, computes one scalar
  `avg = Σ|sample| / frames` (volume) and yields it on `RecordingOutput.amplitude:
  AsyncStream<Float>`.
- `RecordingStage` writes that scalar to `SessionContext.currentAmplitude` and
  `amplitudePublisher`; `SessionController` republishes it; `AudioVisualizer` renders 9
  fixed bars whose heights = a preset phase array × `amplitude*15`.
- Consequence: all 9 bars move together with volume; content is invisible.
- `Accelerate`/`vDSP` is not yet used anywhere (it is a free system framework).

## 3. Data: frequency analysis (the core change)

A new pure module (e.g. `SpectrumAnalyzer`) turns a buffer of 16 kHz mono Float32 samples
into a fixed-size array of normalized band energies:

1. **FFT** via `vDSP` on a power-of-2 window (1024-point; ~15.6 Hz resolution, Nyquist
   8 kHz). Apply a Hann window before the transform to reduce spectral leakage. Take the
   magnitude spectrum.
2. **Log-frequency binning** into `N` bands (N = bar count, default **28**) across the
   speech-relevant range (~80 Hz–6 kHz). Log spacing because human-voice energy clusters in
   the low-mid; linear bins would leave most bars dead.
3. **Normalize** each band (e.g. against a rolling max / fixed reference) to 0–1.
4. **Attack-fast / decay-slow smoothing** per band (exponential: rise quickly toward a new
   higher value, fall slowly) so bars pop up and settle gracefully instead of jittering.

Output: `[Float]` of length `N`, each 0–1.

**Testable seam:** the binning + normalization + smoothing are pure functions over input
arrays — unit-testable in the self-test runner with synthetic spectra (e.g. energy in one
band lights only the corresponding bar; a flat spectrum yields a flat-ish set; smoothing
makes a single spike decay over successive calls). The FFT itself is exercised end-to-end
manually.

## 4. Data flow change (3 touch points, contained)

Replace the scalar-amplitude pipeline with a spectrum pipeline:
- `AudioRecorder`: `RecordingOutput.amplitude: AsyncStream<Float>` → `spectrum:
  AsyncStream<[Float]>`. In the tap callback, instead of computing an average, feed the
  converted samples to `SpectrumAnalyzer` and yield the band array. (If any consumer still
  needs a scalar level, derive it as the spectrum's mean — but the only consumer is the
  visualizer.)
- `SessionContext`: `currentAmplitude: Float` / `amplitudePublisher` → `currentSpectrum:
  [Float]` / `spectrumPublisher: PassthroughSubject<[Float], Never>`.
- `SessionController` (PipelineOrchestrator): the republished `@Published` amplitude becomes
  a `@Published var spectrum: [Float]`.
- `AudioVisualizer`: input `amplitude: Float` → `spectrum: [Float]`; render N mirrored bars.

## 5. Visual

- **~28 thin bars**, small gaps, **grown from the horizontal center line both up and down**
  (symmetric soundwave). Rounded caps.
- **Spatial envelope:** multiply each bar's height by a raised-cosine (Hann-shaped) window
  across bar positions so the **center bars are tallest and edges taper** — a guaranteed
  elegant silhouette at all times. Spectral content varies each bar *within* that envelope.
- Per-bar height = `envelope[i] × bandEnergy[i] × maxBarHeight`.
- **Color: brand purple→blue horizontal gradient** across the bar row (purple on one side,
  blue on the other), echoing the F logo. Per-bar brightness/opacity rises with its energy
  (energetic bars glow brighter). This intentionally pre-stages the brand-visual rollout.
- The visualizer widens from the current 40×24 to fit ~28 bars (the capsule is 320 wide;
  budget ~90–120 pt for the visualizer). Exact size tuned during implementation.

## 6. Animation / feel

- Spectrum updates ~every 85 ms (per converted buffer). **Interpolate between updates** (per
  bar) so motion is fluid, not stepped. Combined with the attack/decay smoothing in §3, bars
  rise fast and fall slowly.
- **Idle (recording but silent):** bars settle to a **low resting wave** plus a very subtle
  slow breathing — alive but calm — rather than going rigidly flat.
- **Not recording:** the capsule panel is hidden, so no idle rendering needed; the resting
  state shows only at recording start before sound arrives.

## 7. Performance

A 1024-point `vDSP` FFT + 28-band reduction per ~85 ms buffer is negligible CPU. No new
threads; runs in the existing audio-tap path (already off the main thread). Bar interpolation
is a lightweight SwiftUI animation.

## 8. Out of scope

- Brand-visual rollout to the windows (separate queued spec) — though the bars' purple→blue
  gradient is a deliberate first step toward it.
- Any change to the capsule's layout, states, glow, or other components.
- Configurability (bar count / colors are fixed constants for now; no settings UI).

## 9. Risks / open points

- **Buffer cadence (~85 ms ≈ 12 fps):** may need interpolation tuning to feel smooth; if too
  coarse, run the FFT on a sliding sub-window more often. Confirm feel on device.
- **Normalization reference:** a fixed reference may clip loud speech or look dead for quiet
  speech; a slow rolling max adapts but can "pump." Tune during implementation.
- **Bar count vs width:** 28 bars must fit legibly in the capsule; final count/width tuned
  visually (24–32 range).
- **Log-bin range (80 Hz–6 kHz):** tuned so typical speech lights the middle bands well.
