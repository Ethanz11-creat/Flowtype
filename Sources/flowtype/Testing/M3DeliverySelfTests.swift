import Foundation

enum M3DeliverySelfTests {
    static func policy(_ r: SelfTest.Reporter) {
        let editable = FocusSignals(secureInputActive: false, focus: .editableText)
        let blind = FocusSignals(secureInputActive: false, focus: .blindOrUnknown)
        let modes: [DeliveryMode] = [.automatic, .unicode, .pasteInSupportedApps]
        let candidates = ["com.apple.TextEdit", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                          "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac"]

        // Removing any safety gate must fail, even for a legacy paste candidate.
        for mode in modes {
            for focus in [FocusKind.editableText, .blindOrUnknown, .nonTextControl] {
                r.eq(resolveDeliveryMethod(mode: mode,
                    signals: .init(secureInputActive: true, focus: focus),
                    accessibilityTrusted: true, bundleID: candidates[0]), .clipboard,
                    "M3 policy: secure input blocks \(mode)/\(focus)")
                r.eq(resolveDeliveryMethod(mode: mode,
                    signals: .init(secureInputActive: false, focus: focus),
                    accessibilityTrusted: false, bundleID: candidates[0]), .clipboard,
                    "M3 policy: no AX permission blocks \(mode)/\(focus)")
            }
            r.eq(resolveDeliveryMethod(mode: mode,
                signals: .init(secureInputActive: false, focus: .nonTextControl),
                accessibilityTrusted: true, bundleID: candidates[0]), .clipboard,
                "M3 policy: non-text focus blocks \(mode)")
        }

        for signals in [editable, blind] {
            for bundleID in candidates.map(Optional.some) + ["test.unknown", "com.apple.Terminal", nil] {
                r.eq(resolveDeliveryMethod(mode: .automatic, signals: signals,
                    accessibilityTrusted: true, bundleID: bundleID), .paste,
                    "M3 policy: automatic permits initial paste for same-target editable/blind apps \(bundleID ?? "nil")")
                r.check(DeliveryMode.automatic.usesPaste(bundleID: bundleID),
                    "M3 policy: automatic has no bundle directory restriction")
                r.eq(resolveDeliveryMethod(mode: .unicode, signals: signals,
                    accessibilityTrusted: true, bundleID: bundleID), .type,
                    "M3 policy: Unicode uses typing for \(bundleID ?? "nil")")
            }
            for bundleID in candidates {
                r.eq(resolveDeliveryMethod(mode: .pasteInSupportedApps, signals: signals,
                    accessibilityTrusted: true, bundleID: bundleID), .paste,
                    "M3 policy: legacy candidate pastes \(bundleID)")
            }
            for bundleID: String? in ["com.apple.Terminal", "test.unknown", nil] {
                r.eq(resolveDeliveryMethod(mode: .pasteInSupportedApps, signals: signals,
                    accessibilityTrusted: true, bundleID: bundleID), .type,
                    "M3 policy: legacy non-candidate types \(bundleID ?? "nil")")
            }
        }

        let target = DeliveryTargetSnapshot(pid: 42, focusIdentity: .init(testID: "editor"), signals: editable)
        let results: [(PasteTransactionResult, Bool)] = [
            (.dispatched, false), (.uncertain, false), (.notDispatched, true),
            (.unsafeSnapshot, true), (.cancelled, false), (.clipboardChanged, false)
        ]
        for (result, permitsFallback) in results {
            for eventDispatched in [false, true] {
                r.eq(canFallbackToTyping(mode: .automatic, pasteResult: result,
                    eventDispatched: eventDispatched, target: target, current: target,
                    accessibilityTrusted: true), eventDispatched ? false : permitsFallback,
                    "M3 fallback: \(result), event=\(eventDispatched)")
            }
        }

        let invalidTargets: [(String, DeliveryTargetSnapshot?, DeliveryTargetSnapshot, Bool)] = [
            ("missing target", nil, target, true),
            ("missing stop PID", .init(pid: nil, signals: editable), target, true),
            ("changed PID", target, .init(pid: 43, signals: editable), true),
            ("missing current PID", target, .init(pid: nil, signals: editable), true),
            ("changed focus", target, .init(pid: 42, focusIdentity: .init(testID: "other"), signals: editable), true),
            ("blind current focus", target, .init(pid: 42, signals: blind), true),
            ("non-text current focus", target, .init(pid: 42, signals: .init(secureInputActive: false, focus: .nonTextControl)), true),
            ("secure current focus", target, .init(pid: 42, signals: .init(secureInputActive: true, focus: .editableText)), true),
            ("secure stop focus", .init(pid: 42, signals: .init(secureInputActive: true, focus: .editableText)), target, true),
            ("non-text stop focus", .init(pid: 42, signals: .init(secureInputActive: false, focus: .nonTextControl)), target, true),
            ("no AX permission", target, target, false)
        ]
        for result: PasteTransactionResult in [.notDispatched, .unsafeSnapshot] {
            for (name, before, current, trusted) in invalidTargets {
                r.check(!canFallbackToTyping(mode: .automatic, pasteResult: result,
                    eventDispatched: false, target: before, current: current, accessibilityTrusted: trusted),
                    "M3 fallback: \(name) denies \(result)")
            }
            for mode: DeliveryMode in [.unicode, .pasteInSupportedApps] {
                r.check(!canFallbackToTyping(mode: mode, pasteResult: result,
                    eventDispatched: false, target: target, current: target, accessibilityTrusted: true),
                    "M3 fallback: explicit legacy mode \(mode) denies \(result)")
            }
            let blindTarget = DeliveryTargetSnapshot(pid: 42, signals: blind)
            r.check(canFallbackToTyping(mode: .automatic, pasteResult: result,
                eventDispatched: false, target: blindTarget, current: target, accessibilityTrusted: true),
                "M3 fallback: refreshed editable focus permits fallback after blind stop snapshot")
        }
    }
}

extension M3DeliverySelfTests {
    /// External board only: the stage, transaction, reservation and event gate are real.
    @MainActor private final class Board: DeliveryPasteboard {
        var value: PasteboardContents
        var changeCount = 0
        var writes: [PasteboardContents] = []
        var incomplete = false
        var failFirstWrite = false
        var afterWriteRead: (() -> Void)?
        init(_ value: PasteboardContents) { self.value = value }
        func contents() -> PasteboardContents? {
            if !writes.isEmpty, let hook = afterWriteRead {
                afterWriteRead = nil
                hook()
            }
            return incomplete ? nil : value
        }
        func write(_ contents: PasteboardContents) -> PasteboardWriteReceipt? {
            changeCount += 1
            writes.append(contents)
            if failFirstWrite && writes.count == 1 {
                value = [["public.utf8-plain-text": Data("partial".utf8)]]
                return .init(changeCount: changeCount, succeeded: false)
            }
            value = contents
            return .init(changeCount: changeCount, succeeded: true)
        }
        func userCopy() {
            changeCount += 1
            value = [["public.utf8-plain-text": Data("user copy".utf8)]]
        }
    }

    @MainActor private final class Signal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if !signalled { await withCheckedContinuation { waiters.append($0) } }
        }
        func signal() {
            signalled = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    @MainActor private final class Runtime {

        let original: PasteboardContents = [
            ["public.rtf": Data("{\\rtf1 original}".utf8), "public.png": Data([0, 1, 2, 255])],
            ["public.file-url": Data("file:///synthetic/example".utf8)]
        ]
        let target = DeliveryTargetSnapshot(pid: 42, focusIdentity: .init(testID: "field"),
            signals: .init(secureInputActive: false, focus: .editableText))
        let text = "完整文本：first\nsecond 😀"
        let context = SessionContext(sessionID: 530)
        let transaction = ClipboardTransaction()
        lazy var board = Board(original)
        var events: [String] = []
        var copies = 0
        var typingCalls = 0
        var modeReads = 0
        var targetReads = 0
        var trustReads = 0
        var selectedMode = Configuration().deliveryMode
        var appID: String? = "test.unknown"
        var prepareFails = false
        var typeFailsBefore = false
        var typeFailsAfter = false
        var cancelBeforeType = false
        var cancelAfterType = false
        var cancelTaskAfterType = false
        var pasteEntered: (() -> Void)?
        var duringPreparation: (() -> Void)?
        var duringFallbackCheck: (() async -> Void)?
        var refreshed: DeliveryTargetSnapshot?
        var refreshedTrust = true
        var settling: (() async -> Void)?
        var pasteResult: PasteTransactionResult?
        var effectBeforeTyping: Bool?
        var eventBeforeTyping: Bool?

        func makeStage() -> InjectionStage {
            context.deliveryTarget = target
            context.finalText = text
            return InjectionStage(settle: {}, accessibilityTrusted: {
                self.trustReads += 1
                return self.trustReads == 1 || self.refreshedTrust
            }, currentTarget: {
                await self.readTarget()
            }, inject: { text, context in
                try await self.type(text, context: context)
            }, mode: {
                self.modeReads += 1
                return self.selectedMode
            }, bundleID: { _ in self.appID }, paste: { text, context, _ in
                self.pasteEntered?()
                let result = await self.transaction.paste(text, context: context, board: self.board,
                    validate: { true }, prepareDispatch: {
                        self.events.append("paste-preparation")
                        self.duringPreparation?()
                        if self.prepareFails { throw InjectionError.eventCreationFailed }
                        return { self.events.append("paste") }
                    }, settle: { await self.settling?() })
                self.pasteResult = result
                return result
            }, copy: { text in
                self.copies += 1
                _ = self.board.write([["public.utf8-plain-text": Data(text.utf8)]])
            })
        }
        func readTarget() async -> DeliveryTargetSnapshot {
            targetReads += 1
            if targetReads > 1 { await duringFallbackCheck?() }
            return targetReads == 1 ? target : refreshed ?? target
        }
        func type(_ text: String, context: SessionContext) throws {
            typingCalls += 1
            effectBeforeTyping = context.deliveryEffectStarted
            eventBeforeTyping = context.deliveryEventStarted
            if cancelBeforeType { context.cancel() }
            if typeFailsBefore { throw InjectionError.eventCreationFailed }
            try KeyboardInjector.postIfActive(context: context) { events.append("type") }
            if cancelAfterType { context.cancel() }
            if cancelTaskAfterType { withUnsafeCurrentTask { $0?.cancel() } }
            if typeFailsAfter { throw InjectionError.eventCreationFailed }
        }
        func execute(_ stage: InjectionStage) async -> StageResult {
            await stage.execute(payload: .polished(text, raw: text), context: context)
        }
    }

    @MainActor static func runtime(_ r: SelfTest.Reporter) async {
        let gate = SessionContext(sessionID: 529)
        _ = gate.beginDeliveryAttempt()
        var effects = 0
        _ = gate.performDeliveryEffectIf { effects += 1; return true }
        r.check(gate.deliveryEffectStarted && !gate.deliveryEventStarted,
                "M3 gate: successful clipboard effect never claims a text event")
        var pairs = 0
        do { try KeyboardInjector.postIfActive(context: gate) { pairs += 1 } }
        catch { r.check(false, "M3 gate: active pair should dispatch") }
        r.check(gate.deliveryEffectStarted && gate.deliveryEventStarted,
                "M3 gate: actual pair claims both latches")
        gate.cancel()
        r.check(!gate.performDeliveryEvent { pairs += 1 }, "M3 gate: cancellation blocks later pair")
        r.eq(pairs, 1, "M3 gate: cancellation never duplicates event")
        r.eq(effects, 1, "M3 gate: event gate does not replay earlier effect")
        r.check(gate.deliveryAttempted && !gate.beginDeliveryAttempt(), "M3 gate: effect/event never reset attempt")
        r.eq(Configuration().deliveryMode, .automatic, "M3 runtime: new default")
        for json in ["{}", #"{"deliveryMode":"future-mode"}"#] {
            let config = try? JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
            r.eq(config?.deliveryMode, .automatic, "M3 runtime: missing/unknown mode migrates")
        }
        for mode: DeliveryMode in [.automatic, .unicode, .pasteInSupportedApps] {
            var config = Configuration()
            config.deliveryMode = mode
            config.polishOnStop = false
            config.maxRecordingDuration = 240
            let encoded = try? JSONEncoder().encode(config)
            let decoded = encoded.flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
            r.eq(decoded?.deliveryMode, mode, "M3 runtime: explicit mode round trips")
            r.eq(decoded?.polishOnStop, false, "M3 runtime: migration preserves polish setting")
            r.eq(decoded?.maxRecordingDuration, 240, "M3 runtime: migration preserves recording setting")
        }

        // A missing fallback or a clipboard-effect/event conflation fails these.
        for failure in ["unsafe", "preparation", "partial-write"] {
            let h = Runtime()
            h.board.incomplete = failure == "unsafe"
            h.prepareFails = failure == "preparation"
            h.board.failFirstWrite = failure == "partial-write"
            let stage = h.makeStage()
            _ = await h.execute(stage)
            _ = await h.execute(stage)
            r.eq(h.events, ["paste-preparation", "type"], "M3 runtime: \(failure) permits exactly one owned typed fallback")
            r.eq(h.board.value, h.original, "M3 runtime: \(failure) fallback preserves all protected representations")
            r.eq(h.pasteResult, failure == "unsafe" ? .unsafeSnapshot : .notDispatched,
                 "M3 runtime: real transaction reports \(failure)")
            r.eq(h.board.writes.count, failure == "partial-write" ? 2 : 0,
                 "M3 runtime: failed write restores once; other failures never write")
            r.eq(h.copies, 0, "M3 runtime: safe fallback never copies")
            r.eq(h.context.deliveryOutcome, .typedDispatched, "M3 runtime: fallback records typed dispatch")
            r.check(h.context.claimHistorySave() && !h.context.claimHistorySave(), "M3 runtime: final result saves once")
            r.eq(h.modeReads, 1, "M3 runtime: one mode snapshot for reserved attempt")
            r.eq(h.eventBeforeTyping, false, "M3 runtime: real failed transaction leaves event gate unclaimed")
            r.eq(h.effectBeforeTyping, false, "M3 runtime: no successful preparation effect for these failures")
        }
        for failure in ["unsafe", "partial-write"] {
            let h = Runtime()
            h.board.incomplete = failure == "unsafe"
            h.board.failFirstWrite = failure == "partial-write"
            h.typeFailsBefore = true
            let result = await h.execute(h.makeStage())
            checkRecovery(result, text: h.text, r: r, label: "\(failure) typing preparation failure")
            r.eq(h.events, ["paste-preparation"], "M3 runtime: pre-key failure emits zero key pairs")
            r.eq(h.board.value, h.original, "M3 runtime: pre-key failure keeps protected board")
            r.eq(h.board.writes.count, failure == "unsafe" ? 0 : 2, "M3 runtime: pre-key failure does not copy")
            r.eq(h.context.deliveryOutcome, nil, "M3 runtime: pre-key failure is recoverable, not uncertain")
            r.eq(h.typingCalls, 1, "M3 runtime: fallback attempted once before recovery")
        }
        for change in ["pid", "focus", "secure", "permission", "blind"] {
            let h = Runtime()
            h.prepareFails = true
            switch change {
            case "pid": h.refreshed = .init(pid: 43, signals: h.target.signals)
            case "focus": h.refreshed = .init(pid: 42, focusIdentity: .init(testID: "other"), signals: h.target.signals)
            case "secure": h.refreshed = .init(pid: 42, signals: .init(secureInputActive: true, focus: .editableText))
            case "permission": h.refreshedTrust = false
            default: h.refreshed = .init(pid: 42, signals: .init(secureInputActive: false, focus: .blindOrUnknown))
            }
            checkRecovery(await h.execute(h.makeStage()), text: h.text, r: r, label: "changed \(change)")
            r.eq(h.typingCalls, 0, "M3 runtime: refreshed \(change) denies fallback")
            r.eq(h.board.value, h.original, "M3 runtime: denied fallback preserves board")
            r.eq(h.copies, 0, "M3 runtime: denied fallback never copies")
        }
        // The terminal result wins once, including when the user replaces the board.
        for terminal in ["dispatched", "uncertain", "clipboardChanged", "userCopyAfterEvent"] {
            let h = Runtime()
            if terminal == "uncertain" { h.settling = { h.context.cancel() } }
            if terminal == "clipboardChanged" { h.board.afterWriteRead = { h.board.userCopy() } }
            if terminal == "userCopyAfterEvent" { h.settling = { h.board.userCopy() } }
            let stage = h.makeStage()
            _ = await h.execute(stage)
            let count = h.board.changeCount
            _ = await h.execute(stage)
            let sent = terminal != "clipboardChanged"
            r.eq(h.events, sent ? ["paste-preparation", "paste"] : ["paste-preparation"],
                 "M3 runtime: \(terminal) is terminal without duplicate events")
            r.eq(h.typingCalls, 0, "M3 runtime: \(terminal) never types")
            r.eq(h.copies, 0, "M3 runtime: \(terminal) never copies")
            r.eq(h.context.deliveryOutcome, terminal == "uncertain" || terminal == "clipboardChanged" ? .uncertain : .pasteDispatched,
                 "M3 runtime: \(terminal) records honest outcome")
            r.eq(h.board.changeCount, count, "M3 runtime: duplicate execute cannot mutate board")
            if terminal == "clipboardChanged" || terminal == "userCopyAfterEvent" {
                r.eq(h.board.value, [["public.utf8-plain-text": Data("user copy".utf8)]], "M3 runtime: user copy retains ownership")
                r.eq(count, 2, "M3 runtime: transaction never restores over user copy")
            } else { r.eq(h.board.value, h.original, "M3 runtime: terminal cleanup restores complete original") }
        }
        for boundary in ["fallback-recheck", "before-first-key", "after-first-key-error", "after-first-key-cancel", "after-first-key-task-cancel"] {
            let h = Runtime()
            h.board.failFirstWrite = true
            if boundary == "before-first-key" { h.cancelBeforeType = true }
            if boundary == "after-first-key-error" { h.typeFailsAfter = true }
            if boundary == "after-first-key-cancel" { h.cancelAfterType = true }
            if boundary == "after-first-key-task-cancel" { h.cancelTaskAfterType = true }
            let entered = Signal()
            let release = Signal()
            if boundary == "fallback-recheck" {
                h.duringFallbackCheck = { entered.signal(); await release.wait() }
            }
            let stage = h.makeStage()
            let task = Task { let result = await h.execute(stage); entered.signal(); return result }
            if boundary == "fallback-recheck" {
                await entered.wait()
                h.context.cancel()
                release.signal()
            }
            _ = await task.value
            _ = await h.execute(stage)
            let sent = boundary.hasPrefix("after-first")
            r.eq(h.events, sent ? ["paste-preparation", "type"] : ["paste-preparation"],
                 "M3 runtime: \(boundary) emits at most one key pair")
            r.eq(h.context.deliveryOutcome, sent ? .uncertain : .cancelled,
                 "M3 runtime: \(boundary) uses event evidence for cancellation")
            r.eq(h.board.value, h.original, "M3 runtime: \(boundary) preserves restored board")
            r.eq(h.copies, 0, "M3 runtime: \(boundary) never copies")
            r.eq(h.board.writes.count, 2, "M3 runtime: \(boundary) only writes temporary board and restoration")
        }
        // Mode changes while preparation runs cannot change the owned strategy.
        do {
            let h = Runtime()
            h.prepareFails = true
            h.duringPreparation = { h.selectedMode = .unicode }
            _ = await h.execute(h.makeStage())
            r.eq(h.events, ["paste-preparation", "type"], "M3 runtime: fallback retains attempt mode snapshot")
            r.eq(h.modeReads, 1, "M3 runtime: settings change does not resample mode")
        }
        // Successful temporary write, then a barrier-controlled task cancellation
        // before the event gate. No invented notDispatched transaction result.
        do {
            let h = Runtime()
            let reached = DispatchSemaphore(value: 0)
            let cancelled = DispatchSemaphore(value: 0)
            h.board.afterWriteRead = {
                reached.signal()
                _ = cancelled.wait(timeout: .now() + 5)
            }
            let stage = h.makeStage()
            let task = Task { await h.execute(stage) }
            let cancellation = Task.detached {
                cancelAtWrite(task, reached: reached, cancelled: cancelled)
            }
            _ = await task.value
            r.check(await cancellation.value, "M3 runtime: cancellation barrier reached successful temporary write")
            r.eq(h.pasteResult, .cancelled, "M3 runtime: successful write then pre-event cancellation is cancelled")
            r.eq(h.events, ["paste-preparation"], "M3 runtime: cancelled prepared paste sends no pair")
            r.eq(h.context.deliveryOutcome, .cancelled, "M3 runtime: temporary write alone is not uncertain")
            r.eq(h.board.value, h.original, "M3 runtime: pre-event cancellation restores original representations")
            r.eq(h.board.writes.count, 2, "M3 runtime: cancellation awaits real cleanup")
            r.eq(h.typingCalls + h.copies, 0, "M3 runtime: cancelled paste never falls back")
            r.check(h.context.deliveryEffectStarted && !h.context.deliveryEventStarted,
                    "M3 runtime: cancelled real temporary write has effect evidence but no event")
        }
        // A cancelled transaction queued behind another clipboard owner never writes.
        do {
            let h = Runtime()
            let holding = Signal()
            let release = Signal()
            let queued = Signal()
            let owner = SessionContext(sessionID: 531)
            let first = Task {
                await h.transaction.paste("first owner", context: owner, board: h.board,
                    validate: { true }, prepareDispatch: { {} }, settle: {
                        holding.signal(); await release.wait()
                    })
            }
            await holding.wait()
            h.pasteEntered = { queued.signal() }
            let second = Task { let result = await h.execute(h.makeStage()); queued.signal(); return result }
            await queued.wait()
            h.context.cancel()
            release.signal()
            r.eq(await first.value, .dispatched, "M3 runtime: first clipboard owner completes")
            _ = await second.value
            r.eq(h.pasteResult, .cancelled, "M3 runtime: queued cancelled transaction exits before snapshot/write")
            r.eq(h.board.writes.count, 2, "M3 runtime: queued cancellation adds no writes")
            r.eq(h.board.value, h.original, "M3 runtime: queued cancellation preserves original")
            r.eq(h.events, [], "M3 runtime: queued cancellation never prepares or types")
            r.eq(h.copies, 0, "M3 runtime: queued cancellation never copies")
        }
        // Explicit modes retain both their routing and their old failure recovery.
        for mode: DeliveryMode in [.unicode, .pasteInSupportedApps] {
            for failure in [false, true] {
                let h = Runtime()
                h.selectedMode = mode
                h.typeFailsBefore = failure
                _ = await h.execute(h.makeStage())
                r.eq(h.events, failure ? [] : ["type"], "M3 runtime: explicit \(mode) non-candidate keeps Unicode")
                r.eq(h.context.deliveryOutcome, failure ? .clipboard : .typedDispatched,
                     "M3 runtime: explicit \(mode) retains pre-effect copy recovery")
                r.eq(h.copies, failure ? 1 : 0, "M3 runtime: explicit mode recovery copy count")
            }
        }
        for failure in [false, true] {
            let h = Runtime()
            h.selectedMode = .pasteInSupportedApps
            h.appID = "com.apple.TextEdit"
            h.prepareFails = failure
            let result = await h.execute(h.makeStage())
            r.eq(h.events, failure ? ["paste-preparation"] : ["paste-preparation", "paste"],
                 "M3 runtime: legacy candidate preserves paste routing")
            r.eq(h.typingCalls + h.copies, 0, "M3 runtime: legacy paste failure does not gain automatic fallback")
            if failure { checkRecovery(result, text: h.text, r: r, label: "legacy preparation failure") }
        }
    }

    @MainActor private static func checkRecovery(_ result: StageResult, text: String,
                                                 r: SelfTest.Reporter, label: String) {
        if case .suspend(let recovery) = result {
            r.eq(recovery.rawText, text, "M3 runtime: \(label) retains full recovery text")
            r.eq(recovery.retryable, false, "M3 runtime: \(label) cannot resend automatically")
        } else { r.check(false, "M3 runtime: \(label) must suspend for explicit recovery") }
    }

    private static func cancelAtWrite(_ task: Task<StageResult, Never>, reached: DispatchSemaphore,
                                      cancelled: DispatchSemaphore) -> Bool {
        let reachedWrite = reached.wait(timeout: .now() + 5) == .success
        task.cancel()
        cancelled.signal()
        return reachedWrite
    }
}
