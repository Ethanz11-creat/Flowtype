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
