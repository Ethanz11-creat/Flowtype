import Foundation

/// Display-only aggregation; permission and engine decisions remain in readiness.
struct ReadinessPresentation {
    let title: String
    let details: [String]
    let destinations: [ClientDestination]

    static func make(snapshot: ReadinessSnapshot, level: ReadinessLevel) -> Self {
        var details: [String] = []
        var destinations: [ClientDestination] = []
        func add(_ issue: ReadinessIssue, _ destination: ClientDestination) {
            if !details.contains(issue.reason) { details.append(issue.reason) }
            if !destinations.contains(destination) { destinations.append(destination) }
        }
        if snapshot.microphone == .denied {
            add(.microphoneDenied, .settings(.privacy, .microphone))
        } else if snapshot.microphone != .granted {
            add(.microphoneNotDetermined, .settings(.privacy, .microphone))
        }
        if snapshot.accessibility != .granted {
            add(.accessibilityMissing, .settings(.privacy, .accessibility))
        }
        if let reason = level.reason, !details.contains(reason) {
            details.append(reason)
            destinations.append(.settings(.speech, .localModels))
        }
        let title: String
        switch level {
        case .blocked: title = "暂时无法听写"
        case .degraded: title = "部分能力受限"
        case .ready: title = "可以开始尝试"
        }
        return Self(title: title, details: details, destinations: destinations)
    }
}

struct SettingsPrivacyPresentation {
    let localPolishDisclosure: String?
    let contextEnabled: Bool
    let polishContextEnabled: Bool

    static func make(config: Configuration) -> Self {
        let enabled = config.asrRoutingPolicy != .localOnly
        return Self(localPolishDisclosure: config.asrRoutingPolicy == .localOnly && config.polishOnStop
            ? "已开启云端文本整理，转写文字仍会发送给整理服务" : nil,
            contextEnabled: enabled, polishContextEnabled: enabled && config.cloudASRSendContext)
    }
}

/// The original request identity is also the scroll trigger for repeated destinations.
struct SettingsLocation: Equatable {
    var section: SettingsSection = .speech
    var target: SettingsTarget?
    var requestID: UUID?

    mutating func consume(_ request: NavigationRequest?) {
        guard let request, case .settings(let section, let target) = request.destination else { return }
        self.section = section
        self.target = target
        requestID = request.id
    }
}
