# FlowType native capsule and waveform

Approved implementation scope from the 2026-11-03 capsule/state/waveform discussion. Primary evidence and prototypes live in `docs/superpowers/research/2026-11-03-{capsule-visual-research,capsule-state-audit,typeless-waveform-study}.md` and the three dated prototype HTML files. Those are design references, not native verification.

## Appearance

Ordinary capsule: **216 × 54 logical points**, radius 27, original blue-purple frosted glass identity (`#855CFF` to `#4DA1FF`). Title 13pt semibold and subtitle 11pt; improve contrast rather than reducing typography. Compact horizontal rhythm; no oversized right spacer. Preserve nonactivation, dragging, all-spaces behavior. Remove whole-panel scale breathing that distorts the selected dimensions. Error recovery retains existing 380 × 156 size and actions; no new panel redesign, buttons, hover controls or Undo.

Recording visualizer: 10 rounded bars, 2pt width, 2pt gaps, intrinsic width 38 in a 40 × 24 region. Rest height 2, normal maximum 18. Original blue-purple colors. Center pulse spreads outwards, slight stable asymmetry, fast attack and slower decay, with time-based behavior rather than buffer-count-dependent speed. Learn the motion mechanism from Typeless, do not copy recovered code. Real, unnormalized PCM amplitude must control overall height: quiet and loud audio stay distinguishable even after sustained input. Frequency detail can shape the bars but cannot substitute for loudness. No synthetic sine, random activity, or perpetual silent motion. Silence, stale input, stop, cancellation, error and a new session all settle/reset safely; no late callback can animate a replacement session. Invalid/empty/nonfinite input must produce bounded finite output. No new dependencies or ASR changes.

## Presentation

Idle hidden. Preparation uses spinner, `正在准备` / `启动麦克风` (retain useful existing preparation diagnostics); recording/countdown starts only after actual PCM, with `Listening...`, elapsed time and `正在听写`, remaining countdown during last 30 seconds.

Processing and polishing share `正在处理`, with `识别语音中` and `整理文字中` respectively. At about 6 seconds after stop, still-active work says `处理时间较长` / `仍在处理，请稍候`. This is progress, never terminal notice: do not release ownership, restart work or extend the existing 20-second completion budget. No artificial processing dwell.

Injecting: `正在输入` / `请保持当前光标`, no green/checkmark success promise. Successful dispatched completion hides promptly. Clipboard completion: `结果已复制` / `按 ⌘V 粘贴`, about 5 seconds, superseded immediately by a new recording. Silence: `未检测到声音` / `请重新录音`; empty: `未录到音频` / `请重新录音`, gentle 2–3 seconds. Polish fallback remains nonblocking with short copy; clipboard and uncertain delivery take priority. Keep notice strings source-compatible if needed, but use explicit structured presentation/outcome metadata rather than classifying arbitrary strings to control timeout or success semantics.

Errors retain typed recovery kind, real reason, and only available actions. Use a meaningful category title. Transient ASR must not promise retrying original audio unless eligible audio exists. Uncertain delivery says `请检查输入结果`, offers copy/history only when available, and never automatically resends. Cancellation hides immediately, invalidates slow/notice timers and ignores late callbacks. Preserve M1–M5 resource/publication/cleanup safeguards. Do not expose partial transcription or make unsupported recovery claims.

## Acceptance

Focused automated checks cover actual PCM loudness order, sustained quiet/loud, silence/rest, malformed samples, time-based propagation, stale input/reset, controller ownership and stale timers, notice priority/duration, ordinary/error geometry and honest presentation. Existing recovery tests continue passing. Native render evidence covers recording, silence, processing, slow, injecting, clipboard, no-speech and error at the real logical sizes. No real cloud call, microphone permission mutation, model download or clipboard write is needed for this verification. Real hardware voice feel remains a separate manual check unless performed.
