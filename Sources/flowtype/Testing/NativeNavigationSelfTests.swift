import Foundation
import Combine

enum NativeNavigationSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) {
        print("--- NativeNavigationSelfTests.repeatedDestinationHasNewIdentity ---")
        repeatedDestinationHasNewIdentity(r)
        print("--- NativeNavigationSelfTests.legacyTabStillNavigates ---")
        legacyTabStillNavigates(r)
        print("--- NativeNavigationSelfTests.destinationKeepsPageSelection ---")
        destinationKeepsPageSelection(r)
    }

    // Catches deduplicating equal destinations, which prevents a second scroll request.
    @MainActor
    static func repeatedDestinationHasNewIdentity(_ r: SelfTest.Reporter) {
        let navigation = SettingsNavigation()
        var received: [NavigationRequest] = []
        let subscription = navigation.$request.compactMap { $0 }.sink { received.append($0) }
        let destination = ClientDestination.settings(.privacy, .microphone)
        let effectsBefore = ValidationEffects.live.snapshot
        let suite = RuntimeEnvironment.current.defaultsSuiteName!
        let defaultsBefore = RuntimeEnvironment.defaults.persistentDomain(forName: suite) ?? [:]

        navigation.navigate(to: destination)
        navigation.navigate(to: destination)

        r.eq(received.count, 2, "repeatedDestinationHasNewIdentity: publishes both requests")
        r.eq(received.map(\.destination), [destination, destination],
             "repeatedDestinationHasNewIdentity: preserves section and target")
        r.eq(Set(received.map(\.id)).count, 2,
             "repeatedDestinationHasNewIdentity: each repeat has a new identity")
        r.eq(navigation.request?.id, received.last?.id,
             "repeatedDestinationHasNewIdentity: current request preserves published identity")
        r.eq(navigation.requestedTab, .settings,
             "repeatedDestinationHasNewIdentity: legacy tab reflects destination")
        r.eq(ValidationEffects.live.snapshot.blocked, effectsBefore.blocked,
             "repeatedDestinationHasNewIdentity: no attempted live audio, input, permissions or network")
        r.eq(ValidationEffects.live.snapshot.permitted, effectsBefore.permitted,
             "repeatedDestinationHasNewIdentity: no live service effects")
        r.check(NSDictionary(dictionary: RuntimeEnvironment.defaults.persistentDomain(forName: suite) ?? [:])
            .isEqual(to: defaultsBefore), "repeatedDestinationHasNewIdentity: no configuration save")
        withExtendedLifetime(subscription) {}
    }

    // Catches a legacy setter that stops reaching the window or emits duplicate requests.
    @MainActor
    static func legacyTabStillNavigates(_ r: SelfTest.Reporter) {
        let navigation = SettingsNavigation(initialTab: .vocab)
        r.eq(navigation.requestedTab, .vocab, "legacyTabStillNavigates: keeps initial tab")
        var received: [NavigationRequest] = []
        let subscription = navigation.$request.compactMap { $0 }.sink { received.append($0) }

        navigation.requestedTab = .history

        r.eq(received.count, 1, "legacyTabStillNavigates: one legacy assignment publishes once")
        r.eq(received.last?.destination, .tab(.history),
             "legacyTabStillNavigates: legacy assignment preserves destination")
        navigation.requestedTab = .history
        r.eq(received.count, 2, "legacyTabStillNavigates: already selected tab remains actionable")
        r.eq(Set(received.map(\.id)).count, 2,
             "legacyTabStillNavigates: repeated legacy assignment gets a fresh identity")
        withExtendedLifetime(subscription) {}
    }

    // Catches dropping record/style IDs or routing their requests to the wrong main page.
    @MainActor
    static func destinationKeepsPageSelection(_ r: SelfTest.Reporter) {
        let navigation = SettingsNavigation()
        let providerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let destinations: [(ClientDestination, AppTab)] = [
            (.history("record-1"), .history), (.history(nil), .history),
            (.style("builtin.structured"), .style), (.style(nil), .style),
            (.settings(.speech, .provider(providerID)), .settings),
            (.settings(.text, nil), .settings), (.tab(.vocab), .vocab)
        ]
        for (destination, tab) in destinations {
            navigation.navigate(to: destination)
            r.eq(navigation.request?.destination, destination,
                 "destinationKeepsPageSelection: preserves associated destination")
            r.eq(navigation.requestedTab, tab,
                 "destinationKeepsPageSelection: selects requested main page")
        }
    }
}
