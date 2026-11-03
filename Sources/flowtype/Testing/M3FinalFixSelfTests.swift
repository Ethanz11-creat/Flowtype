import Foundation
import Combine
import os

/// Regression coverage uses the real chunk loop, InjectionStage, transaction and
/// controller. Only OS targets, balanced event posting, waits and storage are fake.
enum M3FinalFixSelfTests {
    @MainActor private final class Signal {
        var ready = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if !ready { await withCheckedContinuation { waiters.append($0) } }
        }
        func signal() {
            ready = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    @MainActor private final class Board: DeliveryPasteboard {
        let original: PasteboardContents = [["public.png": Data([1, 2, 3]), "public.rtf": Data("original".utf8)]]
        lazy var value = original
        var changeCount = 0
        var writes = 0
        var incomplete = false
        var afterWriteRead: (() -> Void)?
        func contents() -> PasteboardContents? {
            if writes > 0, let hook = afterWriteRead {
                afterWriteRead = nil
                hook()
            }
            return incomplete ? nil : value
        }
        func write(_ contents: PasteboardContents) -> PasteboardWriteReceipt? {
            writes += 1
            changeCount += 1
            value = contents
            return .init(changeCount: changeCount, succeeded: true)
        }
        func userCopy() {
            changeCount += 1
            value = [["public.utf8-plain-text": Data("user copy".utf8)]]
        }
    }

    private struct Stage: PipelineStage {
        let name: String
        let run: @MainActor @Sendable (StagePayload, SessionContext) async -> StageResult
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult { await run(payload, context) }
    }

    @MainActor private final class Fixture {
        let target = DeliveryTargetSnapshot(pid: 42, focusIdentity: .init(testID: "original"),
            signals: .init(secureInputActive: false, focus: .editableText))
        lazy var current = target
        var trusted = true
        var selectedMode: DeliveryMode = .automatic
        var reads = 0
        var onTargetRead: ((Int) async -> Void)?
        let board = Board()
        let transaction = ClipboardTransaction()
        let pairs = OSAllocatedUnfairLock(initialState: [KeyboardInjector.TypingPair]())
        let preparationFails = OSAllocatedUnfairLock(initialState: false)
        var directContext: SessionContext?
        var copies = 0
        var pastes = 0
        var attempts = 0
        var text = String(repeating: "字", count: 140) + "\n尾部"
        var waitAfterPair: (() async -> Void)?
        var settlePaste: (() async -> Void)?
        var afterStage: ((SessionContext) async -> Void)?
        var contexts: [SessionContext] = []
        var histories: [(UInt64, DeliveryOutcome?, String)] = []
        var summaries: [LastDeliverySummary] = []
        var returnedIDs: [UInt64] = []
        var configuration: ConfigurationStore!
        let resources = SessionResourceCoordinator()
        lazy var stage = InjectionStage(settle: {}, accessibilityTrusted: { self.trusted }, currentTarget: {
            await self.readTarget()
        }, typingEvents: .init(prepare: { [pairs, preparationFails] pair in
            if preparationFails.withLock({ $0 }) { throw InjectionError.eventCreationFailed }
            return { pairs.withLock { $0.append(pair) } }
        }, wait: { await self.waitForPair() }), mode: { self.selectedMode }, bundleID: { _ in "synthetic.editor" },
        paste: { text, context, _ in
            self.pastes += 1
            return await self.transaction.paste(text, context: context, board: self.board,
                validate: { true }, prepareDispatch: { { self.attempts += 1 } },
                settle: { await self.settlePaste?() })
        }, copy: { _ in self.copies += 1 })
        lazy var session = makeSession()
        private func makeSession() -> SessionController {
            SessionController(pipeline: [
                Stage(name: "SyntheticText", run: { _, context in
                    self.contexts.append(context)
                    context.deliveryTarget = self.target
                    return .continue(.polished(self.text, raw: self.text))
                }),
                Stage(name: "RealInjectionBoundary", run: { payload, context in
                    let result = await self.stage.execute(payload: payload, context: context)
                    await self.afterStage?(context)
                    self.returnedIDs.append(context.sessionID)
                    return result
                })
            ], observers: [], effects: SessionEffects(prepare: {}, showWindow: {}, hideWindow: {},
                saveHistory: { self.histories.append(($0.sessionID, $0.deliveryOutcome, $0.finalText)) }),
                configurationStore: configuration, refreshReadiness: { .ready }, readinessLevel: { .ready }, resources: resources)
        }
        func readTarget() async -> DeliveryTargetSnapshot {
            reads += 1
            await onTargetRead?(reads)
            return current
        }
        func waitForPair() async { await waitAfterPair?() }
        func execute() async -> (StageResult, SessionContext) {
            let context = SessionContext(sessionID: 900)
            directContext = context
            context.deliveryTarget = target
            context.finalText = text
            return (await stage.execute(payload: .polished(text, raw: text), context: context), context)
        }
    }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await targetChanges(r)
        await primaryTypingTargetChanges(r)
        await loopBoundaries(r)
        await controllerCancellation(r)
    }

    @MainActor private static func primaryTypingTargetChanges(_ r: SelfTest.Reporter) async {
        for mode: DeliveryMode in [.unicode, .pasteInSupportedApps] {
            for change in ["pid", "identity", "secure", "permission", "nontext"] {
                for boundary in ["first", "chunk", "before-newline", "after-newline"] {
                    let f = Fixture()
                    f.selectedMode = mode
                    if boundary == "before-newline" { f.text = "first\nsecond" }
                    if boundary == "after-newline" { f.text = "\nsecond" }
                    if boundary == "first" {
                        f.onTargetRead = { count in if count == 2 { Self.change(change, fixture: f) } }
                    } else {
                        f.waitAfterPair = { Self.change(change, fixture: f) }
                    }
                    let (_, context) = await f.execute()
                    let sent = f.pairs.withLock { $0 }
                    let label = "CORE02 \(mode) \(change)/\(boundary)"
                    r.eq(sent.count, boundary == "first" ? 0 : 1, "\(label): no later event escapes")
                    if boundary == "after-newline" { r.eq(sent.first, .newline, "\(label): checks after newline too") }
                    r.eq(context.deliveryOutcome, boundary == "first" ? .clipboard : .uncertain,
                         "\(label): outcome follows actual escaped events")
                    r.eq(f.copies, boundary == "first" ? 1 : 0, "\(label): never duplicates partial typing")
                    r.eq(f.pastes, 0, "\(label): no paste retry")
                }
            }
            let blind = Fixture()
            blind.selectedMode = mode
            blind.current = .init(pid: 42, signals: .init(secureInputActive: false, focus: .blindOrUnknown))
            let (_, context) = await blind.execute()
            r.eq(context.deliveryOutcome, .typedDispatched, "CORE02: primary typing retains same-process unknown AX compatibility")
            r.eq(blind.pairs.withLock { $0.count }, 5, "CORE02: unknown AX does not lose safe text")
            for afterFirst in [false, true] {
                let cancelled = Fixture()
                cancelled.selectedMode = mode
                cancelled.onTargetRead = { count in
                    if count == (afterFirst ? 3 : 2) {
                        await Task.yield()
                        cancelled.directContext?.cancel()
                    }
                }
                let (_, stopped) = await cancelled.execute()
                r.eq(cancelled.pairs.withLock { $0.count }, afterFirst ? 1 : 0,
                     "CORE02: cancellation during primary validator blocks the next pair")
                r.eq(stopped.deliveryOutcome, afterFirst ? .uncertain : .cancelled,
                     "CORE02: primary cancellation retains actual event evidence")
                r.eq(cancelled.copies + cancelled.pastes, 0,
                     "CORE02: cancellation never copies or resends text")
            }
        }
    }

    @MainActor private static func targetChanges(_ r: SelfTest.Reporter) async {
        // The third read is immediately before the first pair. Earlier reads are
        // initial routing and admission to fallback, so this also closes that gap.
        for change in ["pid", "identity", "secure", "permission", "blind", "nontext"] {
            for boundary in ["first", "chunk", "before-newline", "after-newline"] {
                let f = Fixture()
                f.board.incomplete = true
                if boundary == "before-newline" { f.text = "first\nsecond" }
                if boundary == "after-newline" { f.text = "\nsecond" }
                let entered = Signal(), release = Signal()
                if boundary == "first" {
                    f.onTargetRead = { count in
                        if count == 3 { Self.change(change, fixture: f) }
                    }
                } else {
                    f.waitAfterPair = { entered.signal(); await release.wait() }
                }
                let task = Task { await f.execute() }
                if boundary != "first" {
                    await entered.wait()
                    Self.change(change, fixture: f)
                    release.signal()
                }
                let (result, context) = await task.value
                let label = "M3 final F1 \(change)/\(boundary)"
                let sent = f.pairs.withLock { $0 }
                r.eq(sent.count, boundary == "first" ? 0 : 1, "\(label): no pair after rejection")
                if boundary == "after-newline" { r.eq(sent.first, .newline, "\(label): actual newline dispatched first") }
                if boundary == "first" {
                    if case .suspend(let recovery) = result {
                        r.eq(recovery.rawText, f.text, "\(label): full text recovery")
                        r.check(!recovery.retryable, "\(label): no automatic retry")
                    } else { r.check(false, "\(label): rejection before first pair suspends") }
                } else { r.eq(context.deliveryOutcome, .uncertain, "\(label): partial delivery uncertain") }
                r.eq(f.board.value, f.board.original, "\(label): original multi-format board preserved")
                r.eq(f.board.writes + f.copies, 0, "\(label): no copy or board mutation")
                r.check(context.deliveryAttempted && !context.beginDeliveryAttempt(), "\(label): attempt stays latched")
            }
        }
    }

    @MainActor private static func loopBoundaries(_ r: SelfTest.Reporter) async {
        let success = Fixture()
        success.board.incomplete = true
        let (_, completed) = await success.execute()
        r.eq(success.pairs.withLock { $0 }, [.unicode(String(repeating: "字", count: 64)),
            .unicode(String(repeating: "字", count: 64)), .unicode(String(repeating: "字", count: 12)),
            .newline, .unicode("尾部")], "M3 final F1: production loop preserves chunk and newline ordering")
        r.eq(completed.deliveryOutcome, .typedDispatched, "M3 final F1: safe whole text dispatched")
        r.eq(success.reads, 7, "M3 final F1: initial, admission and every pair use fresh target")

        for afterFirst in [false, true] {
            let f = Fixture()
            f.board.incomplete = true
            f.onTargetRead = { read in
                if read == (afterFirst ? 4 : 3) {
                    // The target await itself can finish after cancellation. A fresh
                    // safe snapshot must never permit a pair in that case.
                    await Task.yield()
                    f.directContext?.cancel()
                }
            }
            let (_, context) = await f.execute()
            r.eq(f.pairs.withLock { $0.count }, afterFirst ? 1 : 0,
                 "M3 final F1: cancellation during validation blocks next pair")
            r.eq(context.deliveryOutcome, afterFirst ? .uncertain : .cancelled,
                 "M3 final F1: validation cancellation uses actual event evidence")
            r.eq(f.copies + f.board.writes, 0, "M3 final F1: validation cancellation never copies")

            let failed = Fixture()
            failed.board.incomplete = true
            if afterFirst { failed.waitAfterPair = { failed.preparationFails.withLock { $0 = true } } }
            else { failed.preparationFails.withLock { $0 = true } }
            let (result, failedContext) = await failed.execute()
            r.eq(failed.pairs.withLock { $0.count }, afterFirst ? 1 : 0,
                 "M3 final F1: preparation failure sends no additional pair")
            r.eq(failedContext.deliveryEventStarted, afterFirst, "M3 final F1: preparation never claims event latch")
            if afterFirst { r.eq(failedContext.deliveryOutcome, .uncertain, "M3 final F1: late preparation failure uncertain") }
            else if case .suspend(let recovery) = result {
                r.eq(recovery.rawText, failed.text, "M3 final F1: first preparation failure retains text")
            } else { r.check(false, "M3 final F1: first preparation failure suspends") }
            r.eq(failed.copies + failed.board.writes, 0, "M3 final F1: preparation failure preserves board")
        }
    }

    @MainActor private static func change(_ kind: String, fixture f: Fixture) {
        switch kind {
        case "pid": f.current = .init(pid: 99, signals: f.target.signals)
        case "identity": f.current = .init(pid: 42, focusIdentity: .init(testID: "other"), signals: f.target.signals)
        case "secure": f.current = .init(pid: 42, signals: .init(secureInputActive: true, focus: .editableText))
        case "permission": f.trusted = false
        case "blind": f.current = .init(pid: 42, signals: .init(secureInputActive: false, focus: .blindOrUnknown))
        default: f.current = .init(pid: 42, signals: .init(secureInputActive: false, focus: .nonTextControl))
        }
    }

    @MainActor private static func controllerCancellation(_ r: SelfTest.Reporter) async {
        let suite = "FlowTypeM3FinalFix.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { r.check(false, "M3 final isolated defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = ConfigurationStore(defaults: defaults)
        for kind in ["paste", "paste-user-copy", "typing", "pending-paste", "pending-typing", "effect-only"] {
            let f = Fixture()
            f.configuration = configuration
            f.board.incomplete = kind.contains("typing")
            let entered = Signal(), release = Signal()
            let pending = kind.hasPrefix("pending")
            if pending {
                f.afterStage = { _ in entered.signal(); await release.wait() }
            } else if kind.contains("typing") {
                f.waitAfterPair = { entered.signal(); await release.wait() }
            } else if kind != "effect-only" {
                f.settlePaste = { entered.signal(); await release.wait() }
            }
            let session = f.session
            let subscription = session.$lastDeliverySummary.sink { if let summary = $0 { f.summaries.append(summary) } }
            if kind == "effect-only" {
                // Hold the entered boundary after the real cancelled stage returns,
                // so its lease drain is deterministic rather than scheduler-dependent.
                f.afterStage = { _ in await release.wait() }
                f.board.afterWriteRead = { session.cancel(); entered.signal() }
            }
            session.startRecording()
            await entered.wait()
            guard let old = f.contexts.first else { r.check(false, "M3 final context exists"); continue }
            let label = "M3 final F2 \(kind)"
            if kind != "effect-only" {
                r.check(old.deliveryEventStarted, "\(label): actual event evidence before cancel")
                r.eq(old.deliveryOutcome, pending ? (kind.contains("typing") ? .typedDispatched : .pasteDispatched) : nil,
                     "\(label): exact pending outcome before cancel")
                if kind == "paste-user-copy" { f.board.userCopy() }
                session.cancel()
                r.eq(old.deliveryOutcome, .uncertain, "\(label): cancellation materializes uncertain synchronously")
                r.eq(f.histories.count, 1, "\(label): history saved while still owner")
                r.eq(f.histories.first?.1, .uncertain, "\(label): saved outcome uncertain")
                r.eq(f.histories.first?.2, f.text, "\(label): full recovery text saved")
                r.eq(session.lastDeliverySummary?.sessionID, old.sessionID, "\(label): summary owns cancelled session")
                r.eq(session.lastDeliverySummary?.outcome, .uncertain, "\(label): immediate uncertain summary")
            } else {
                r.check(old.deliveryEffectStarted && !old.deliveryEventStarted, "\(label): temporary board only")
                r.eq(f.histories.count, 0, "\(label): no event means no history")
                r.eq(session.lastDeliverySummary, nil, "\(label): no event means no summary")
            }
            session.cancel()
            // Task7 retains the recording/pipeline owner through actual cleanup.
            // A competing explicit start is rejected; draining never queues it.
            let drainingOwner = f.resources.owner
            let cancelledSummary = session.lastDeliverySummary
            let savedCount = f.histories.count, summaryCount = f.summaries.count
            r.check(drainingOwner != nil, "\(label): cancelled boundary retains resource until return")
            f.trusted = false
            f.afterStage = nil
            session.startRecording()
            r.check(session.resourceBusyNotice != nil, "\(label): competing start blocked during cleanup")
            r.eq(f.resources.owner, drainingOwner, "\(label): competing start preserves draining owner")
            r.eq(f.contexts.count, 1, "\(label): no new capture before cleanup")
            r.eq(f.copies, 0, "\(label): competing start cannot copy")
            r.eq(f.histories.count, savedCount, "\(label): competing start cannot save history")
            r.eq(f.summaries.count, summaryCount, "\(label): competing start cannot publish summary")
            release.signal()
            await waitUntil { f.returnedIDs.contains(old.sessionID) && f.resources.owner == nil }
            r.check(f.returnedIDs.contains(old.sessionID), "\(label): old real stage exited after cleanup")
            r.eq(f.resources.owner, nil, "\(label): old boundary return releases resource")
            r.eq(f.contexts.count, 1, "\(label): cleanup cannot queue a new session")
            r.eq(session.lastDeliverySummary, cancelledSummary, "\(label): late cleanup preserves cancelled summary")
            r.eq(f.histories.count, savedCount, "\(label): once-only history after late cleanup")
            r.eq(f.summaries.count, summaryCount, "\(label): once-only summary after late cleanup")
            session.startRecording()
            await waitUntil { f.contexts.count == 2 && session.lastDeliverySummary?.outcome == .clipboard }
            let newer = session.lastDeliverySummary
            r.check(newer?.sessionID != old.sessionID && newer != nil, "\(label): explicit restart completes after actual cleanup")
            r.eq(f.histories.count, savedCount + 1, "\(label): explicit new delivery saves history once")
            r.eq(f.summaries.count, summaryCount + 1, "\(label): explicit new delivery publishes summary once")
            old.statePublisher.send(.injecting)
            r.eq(session.lastDeliverySummary, newer, "\(label): stale old callback cannot replace newer summary")
            r.eq(f.pastes, 1, "\(label): no paste retry")
            r.eq(f.copies, 1, "\(label): only newer session copies")
            if kind == "paste-user-copy" {
                r.eq(f.board.value, [["public.utf8-plain-text": Data("user copy".utf8)]], "\(label): cleanup preserves user-owned board")
            } else { r.eq(f.board.value, f.board.original, "\(label): original board restored/preserved") }
            if kind == "typing" { r.eq(f.pairs.withLock { $0.count }, 1, "\(label): partial typing stops after cancel") }
            let completed = f.contexts.last
            let completedOutcome = completed?.deliveryOutcome
            session.cancel()
            r.eq(completed?.deliveryOutcome, completedOutcome, "\(label): completed session remains unchanged")
            subscription.cancel()
        }
    }

    @MainActor private static func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
