import Foundation
import Combine

enum CapsulePresentationSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        r.eq(SessionState.recording(elapsedSeconds: 3).capsuleSize.width, 216, "capsule: ordinary width is 216")
        r.eq(SessionState.preparing.capsuleSize.height, 54, "capsule: ordinary height is 54")
        r.eq(SessionState.error("reason").capsuleSize.width, 380, "capsule: recovery width retained")
        r.eq(SessionState.error("reason").capsuleSize.height, 156, "capsule: recovery height retained")
        r.eq(SessionState.preparing.statusTitle, "正在准备", "capsule: preparation title")
        r.eq(SessionState.processing(provider: "private provider").statusTitle, "正在处理", "capsule: processing title")
        r.eq(SessionState.injecting.statusTitle, "正在输入", "capsule: injecting title")
        let missing = RecoveryPolicy.presentation(kind: .transientASR, resources: .init(stage: "ASR", hasAudio: false,
            textKind: .none, deliveryEventStarted: false, routingPolicy: .auto, hasHistory: false))
        r.check(!missing.message.contains("重试原录音"), "capsule: missing audio cannot promise original-audio retry")
        presentation(r)
        await emission(r)
        await lifecycle(r)
    }
}

extension CapsulePresentationSelfTests {
    @MainActor private static func presentation(_ r: SelfTest.Reporter) {
        let cases: [(SessionState, String, String, CapsulePresentation.Indicator)] = [
            (.preparing, "正在准备", "启动麦克风", .spinner),
            (.recording(elapsedSeconds: 12), "Listening...", "正在听写", .waveform),
            (.processing(provider: "private"), "正在处理", "识别语音中", .spinner),
            (.polishing(preview: "private draft"), "正在处理", "整理文字中", .spinner),
            (.injecting, "正在输入", "请保持当前光标", .symbol("text.cursor"))
        ]
        for (state, title, subtitle, indicator) in cases {
            let p = CapsulePresentation(state: state)
            r.eq(p.title, title, "capsule presentation: \(title) title")
            r.eq(p.subtitle, subtitle, "capsule presentation: \(title) subtitle")
            r.eq(p.indicator, indicator, "capsule presentation: \(title) semantic indicator")
            r.eq(p.size, NSSize(width: 216, height: 54), "capsule presentation: ordinary geometry")
            r.check(!p.hidden, "capsule presentation: active state visible")
        }
        r.check(CapsulePresentation(state: .idle).hidden, "capsule presentation: idle hidden")
        r.eq(CapsulePresentation(state: .recording(elapsedSeconds: 12)).timer, "00:12", "capsule presentation: elapsed recording time")
        r.eq(CapsulePresentation(state: .recording(elapsedSeconds: 280), maxRecordingDuration: 300).timer, "剩余 20s", "capsule presentation: final thirty seconds countdown")
        r.eq(CapsulePresentation(state: .preparing, preparationNotice: "识别引擎准备中").subtitle, "识别引擎准备中", "capsule presentation: useful preparation diagnostic retained")
        for state: SessionState in [.processing(provider: "x"), .polishing(preview: "private")] {
            let p = CapsulePresentation(state: state, slow: true)
            r.eq(p.title, "处理时间较长", "capsule presentation: slow title")
            r.eq(p.subtitle, "仍在处理，请稍候", "capsule presentation: slow subtitle")
            r.eq(p.indicator, .spinner, "capsule presentation: slow work remains progress")
        }
        let notices: [(CapsuleNotice, String, String)] = [
            (.resourceBusy, "暂时无法开始", "资源使用中，请稍后再试"),
            (.noSpeech, "未检测到声音", "请重新录音"), (.emptyAudio, "未录到音频", "请重新录音"),
            (.clipboard, "结果已复制", "按 ⌘V 粘贴"), (.polishFallback(.failed), "已保留识别结果", "整理未完成"),
            (.polishFallback(.timedOut), "已保留识别结果", "整理超时"),
            (.polishFallback(.literalPreserved), "技术内容已保留", "已使用识别结果")
        ]
        for (notice, title, subtitle) in notices {
            let p = CapsulePresentation(state: .notice("unrelated source-compatible text"), notice: notice)
            r.eq(p.title, title, "capsule presentation: typed notice title")
            r.eq(p.subtitle, subtitle, "capsule presentation: typed notice action")
            r.eq(notice.duration, notice == .clipboard ? 5 : 2.2, "capsule presentation: typed duration")
            r.check(p.indicator != .waveform && p.indicator != .spinner, "capsule presentation: terminal notice never animates audio/progress")
        }
        r.eq(CapsuleNotice.completion(outcome: .clipboard, fallback: .polishFallback(.failed)), .clipboard, "capsule presentation: clipboard outranks polish fallback")
        r.eq(CapsuleNotice.completion(outcome: .uncertain, fallback: .polishFallback(.failed)), nil, "capsule presentation: uncertain delivery suppresses polish notice")
        r.eq(CapsuleNotice.completion(outcome: .typedDispatched, fallback: .polishFallback(.failed)), .polishFallback(.failed), "capsule presentation: dispatched fallback remains nonblocking")
        for kind: FailureKind in [.deliveryUncertain, .deliveryBlocked] {
            let missing = RecoveryPolicy.presentation(kind: kind, resources: .init(stage: "Injection", hasAudio: false,
                textKind: .none, deliveryEventStarted: kind == .deliveryUncertain, routingPolicy: .auto, hasHistory: false))
            r.check(!missing.message.contains("复制结果"), "capsule presentation: \(kind) without result never claims available copy")
            r.check(!missing.actions.contains(.copyResult), "capsule presentation: absent result has no copy action")
            let card = RecoveryCard(id: UUID(), sessionID: 1, presentation: missing)
            let p = CapsulePresentation(state: .error(missing.message), recoveryCard: card)
            r.eq(p.size, NSSize(width: 380, height: 156), "capsule presentation: recovery geometry")
            if kind == .deliveryUncertain { r.eq(p.title, "请检查输入结果", "capsule presentation: honest uncertainty title") }
            r.check(!p.actions.contains(.retry(stage: "Injection")), "capsule presentation: no automatic resend offer")
        }
    }

    @MainActor private static func emission(_ r: SelfTest.Reporter) async {
        for (decision, notice, message): (SpeechPreflightDecision, CapsuleNotice, String) in [
            (.clearlySilent, .noSpeech, "未检测到声音，请重试"), (.emptyCapture, .emptyAudio, "未录到音频，请重试")
        ] {
            let context = SessionContext(sessionID: 1)
            let result = await ASRStage(speechPreflight: { _, _ in decision }).execute(payload: .audio(samples: [], previewText: ""), context: context)
            r.eq(context.capsuleNotice, notice, "capsule source: real ASR stage emits typed gentle metadata")
            if case .notice(let actual) = result { r.eq(actual, message, "capsule source: legacy ASR notice remains compatible") }
            else { r.check(false, "capsule source: ASR returns gentle notice") }
        }
        let context = SessionContext(sessionID: 2)
        context.capsuleNotice = .polishFallback(.timedOut)
        context.completionNotice = "legacy polish fallback"
        var copies = 0
        let stage = InjectionStage(settle: {}, accessibilityTrusted: { false }, currentTarget: { .init(pid: nil) },
            mode: { .unicode }, bundleID: { _ in nil }, copy: { _ in copies += 1 })
        _ = await stage.execute(payload: .polished("synthetic complete text", raw: "raw"), context: context)
        r.eq(copies, 1, "capsule source: real injection uses isolated copy seam once")
        r.eq(context.capsuleNotice, .clipboard, "capsule source: actual clipboard metadata replaces polish fallback")
        r.eq(context.deliveryOutcome, .clipboard, "capsule source: clipboard outcome remains honest")
    }

    private struct Stage: PipelineStage {
        let name = "Synthetic capsule capture"
        let run: @MainActor @Sendable (SessionContext) async -> StageResult
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult { await run(context) }
    }

    @MainActor private final class Waits {
        struct Entry { let seconds: Double; let continuation: CheckedContinuation<Void, any Error> }
        var entries: [Entry] = []
        var now: Double = 100
        var timing: CapsulePresentationTiming { .init(now: { self.now }, delay: { seconds in
            // Deliberately non-cooperative: cancelling a Task must not be the ownership guard.
            try await withCheckedThrowingContinuation { self.entries.append(.init(seconds: seconds, continuation: $0)) }
        }) }
        func resume(_ index: Int) { entries[index].continuation.resume() }
    }

    @MainActor private final class Capture {
        var contexts: [SessionContext] = []
        var pending: [CheckedContinuation<StageResult, Never>?] = []
        func run(_ context: SessionContext) async -> StageResult {
            contexts.append(context)
            context.markReady()
            return await withCheckedContinuation { pending.append($0) }
        }
        func finish(_ index: Int, result: StageResult = .complete) {
            pending[index]?.resume(returning: result); pending[index] = nil
        }
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor private static func lifecycle(_ r: SelfTest.Reporter) async {
        let suite = "FlowTypeCapsule.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(defaults: defaults), waits = Waits(), capture = Capture()
        let resources = SessionResourceCoordinator()
        let c = SessionController(pipeline: [Stage(run: { await capture.run($0) })], observers: [],
            effects: .init(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in }),
            recoveryEffects: .init(openAccessibilitySettings: {}, openMicrophoneSettings: {}, openSpeechRecognitionSettings: {},
                openASRSettings: {}, openHistory: {}, copyText: { _ in }), configurationStore: store,
            refreshReadiness: { .ready }, readinessLevel: { .ready }, presentationTiming: waits.timing,
            purpose: .trial, resources: resources)
        c.startRecording(); await wait { capture.pending.count == 1 }
        c.endRecording()
        await wait { !waits.entries.isEmpty }
        r.check(!waits.entries.isEmpty, "capsule controller: stop schedules one slow signal")
        guard !waits.entries.isEmpty else { c.cancel(); capture.finish(0); return }
        r.eq(waits.entries[0].seconds, 6, "capsule controller: slow threshold is six seconds from stop")
        let first = capture.contexts[0]
        let budget = first.completionBudget
        first.statePublisher.send(.processing(provider: "new provider"))
        first.statePublisher.send(.polishing(preview: "must stay private"))
        r.eq(waits.entries.count, 1, "capsule controller: provider and polish updates never restart slow clock")
        waits.now = 106; waits.resume(0)
        await wait { c.capsulePresentation.title == "处理时间较长" }
        r.eq(c.capsulePresentation.title, "处理时间较长", "capsule controller: slow work is visible")
        r.eq(c.sessionState, .polishing(preview: "must stay private"), "capsule controller: slow signal is never a terminal lifecycle state")
        r.check(resources.owner != nil && !first.isCancelled, "capsule controller: slow display retains ownership")
        r.eq(first.completionBudget, budget, "capsule controller: slow signal does not replace completion budget")
        c.cancel(); capture.finish(0); await wait { resources.owner == nil }
        r.eq(c.sessionState, .idle, "capsule controller: cancel hides slow operation immediately")

        c.startRecording(); await wait { capture.pending.count == 2 }
        c.endRecording(); await wait { waits.entries.count == 2 }
        c.cancel(); capture.finish(1); await wait { resources.owner == nil }
        c.startRecording(); await wait { capture.pending.count == 3 }
        waits.now = 112; waits.resume(1)
        for _ in 0..<10 { await Task.yield() }
        r.eq(c.capsulePresentation.title, "Listening...", "capsule controller: cancelled slow callback cannot repaint replacement")
        c.endRecording(); await wait { waits.entries.count == 3 }
        var armed = true
        let observer = c.objectWillChange.sink {
            guard armed, c.capsulePresentation.title == "处理时间较长" else { return }
            armed = false; c.cancel()
        }
        waits.now = 118; waits.resume(2)
        await wait { c.sessionState == .idle }
        r.eq(c.sessionState, .idle, "capsule controller: synchronous cancellation during slow publication wins")
        r.check(c.capsulePresentation.hidden, "capsule controller: reentrant cancellation keeps presentation hidden")
        observer.cancel(); capture.finish(2); await wait { resources.owner == nil }

        // Actual delivery must outrank a prior polish fallback, regardless of legacy message text.
        c.startRecording(); await wait { capture.pending.count == 4 }
        let clipboard = capture.contexts[3]
        clipboard.capsuleNotice = .polishFallback(.failed)
        clipboard.completionNotice = "整理失败 · 已保留识别结果"
        _ = clipboard.beginDeliveryAttempt(); clipboard.finishDelivery(.clipboard)
        capture.finish(3)
        await wait { if case .notice = c.sessionState { return true }; return false }
        await wait { waits.entries.count == 4 }
        r.eq(c.capsulePresentation.title, "结果已复制", "capsule controller: actual clipboard outcome beats fallback metadata")
        r.eq(waits.entries[3].seconds, 5, "capsule controller: clipboard remains five seconds")
        c.startRecording(); await wait { capture.pending.count == 5 }
        let replacement = capture.contexts[4]
        replacement.capsuleNotice = .noSpeech
        capture.finish(4, result: .notice("unrelated legacy text"))
        await wait { waits.entries.count == 5 }
        r.eq(c.capsulePresentation.title, "未检测到声音", "capsule controller: source metadata provides gentle notice copy")
        r.eq(waits.entries[4].seconds, 2.2, "capsule controller: gentle notice duration")
        waits.resume(3)
        for _ in 0..<10 { await Task.yield() }
        r.eq(c.capsulePresentation.title, "未检测到声音", "capsule controller: old zero-session notice timer cannot dismiss newer notice")
        waits.resume(4); await wait { c.sessionState == .idle }
        r.eq(c.sessionState, .idle, "capsule controller: owned notice timer dismisses")
        c.startRecording(); await wait { capture.pending.count == 6 }
        capture.finish(5, result: .notice("已复制，按 ⌘V 粘贴"))
        await wait { waits.entries.count == 6 }
        r.eq(waits.entries[5].seconds, 2.2, "capsule controller: arbitrary clipboard-looking string cannot select outcome duration")
        c.cancel(); waits.resume(5)
        c.startRecording(); await wait { capture.pending.count == 7 }
        let uncertain = capture.contexts[6]
        uncertain.capsuleNotice = .polishFallback(.failed)
        uncertain.completionNotice = "fallback must not hide uncertain result"
        uncertain.finalText = "complete result"
        _ = uncertain.performDeliveryEvent {}
        uncertain.finishDelivery(.uncertain)
        capture.finish(6)
        await wait { if case .error = c.sessionState { return true }; return false }
        r.eq(c.capsulePresentation.title, "请检查输入结果", "capsule controller: uncertain actual delivery outranks polish fallback")
        r.check(c.errorActions.contains(.copyResult), "capsule controller: retained complete result offers copy")
        r.eq(waits.entries.count, 6, "capsule controller: recovery never schedules gentle dismissal")
        c.cancel()
    }
}
