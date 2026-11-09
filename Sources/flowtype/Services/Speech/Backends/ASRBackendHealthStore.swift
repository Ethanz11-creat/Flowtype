import Foundation
import os

/// Health belongs to a call configuration and its credential version. No secret or URL is a key.
final class ASRBackendHealthStore: Sendable {
    struct Key: Hashable, Sendable {
        let id: ASRBackendID
        let revision: UUID
        let modelID: String?
        let credentialGeneration: UUID?
        let requiresInternet: Bool
        init(_ binding: ASRBackendBinding) {
            id = binding.descriptor.id; revision = binding.descriptor.revision
            modelID = binding.descriptor.modelID; credentialGeneration = binding.credentialGeneration
            requiresInternet = binding.descriptor.requiresInternet
        }
    }
    private struct Sample: Sendable {
        var consecutiveFailures = 0
        var latencyEWMA: Double = 0
        var sampledAt: Date?
        var probeMs: Double?
        var probeAt: Date?
        var probeFailed = false
        var lastRecoveryUptime: UInt64?
        var degraded: Bool {
            consecutiveFailures >= ASRRoutingThresholds.cloudFailureStreak
                || agedLatencySample(latencyEWMA, sampledAt: sampledAt, now: Date(), ttl: ASRRouterProbeConfig.latencyTtl) > ASRRoutingThresholds.cloudLatencyMs
                || probeFailed || (sampleIsFresh(sampledAt: probeAt, now: Date(), ttl: ASRRouterProbeConfig.ttl)
                    && (probeMs ?? 0) > ASRRoutingThresholds.cloudProbeHandshakeMs)
        }
    }
    private struct State { var samples: [Key: Sample] = [:]; var networkGeneration: UInt64 = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func recordSuccess(binding: ASRBackendBinding, latencyMs: Int) {
        state.withLock {
            var sample = $0.samples[Key(binding)] ?? Sample()
            sample.latencyEWMA = updateLatencyEWMA(previous: sample.degraded ? 0 : sample.latencyEWMA, sample: Double(latencyMs))
            sample.consecutiveFailures = 0; sample.sampledAt = Date()
            sample.probeFailed = false; sample.probeMs = nil; sample.probeAt = nil
            $0.samples[Key(binding)] = sample
        }
    }
    func recordFailure(binding: ASRBackendBinding) {
        state.withLock { $0.samples[Key(binding), default: Sample()].consecutiveFailures += 1 }
    }
    func isDegraded(binding: ASRBackendBinding) -> Bool {
        state.withLock { $0.samples[Key(binding)]?.degraded ?? false }
    }
    func probeIsFresh(binding: ASRBackendBinding) -> Bool {
        state.withLock { sampleIsFresh(sampledAt: $0.samples[Key(binding)]?.probeAt, now: Date(), ttl: ASRRouterProbeConfig.ttl) }
    }
    var networkGeneration: UInt64 { state.withLock { $0.networkGeneration } }
    func recordProbe(binding: ASRBackendBinding, generation: UInt64, latencyMs: Double?) {
        state.withLock {
            guard $0.networkGeneration == generation else { return }
            var sample = $0.samples[Key(binding)] ?? Sample()
            sample.probeMs = latencyMs; sample.probeAt = Date(); sample.probeFailed = latencyMs == nil
            $0.samples[Key(binding)] = sample
        }
    }
    func invalidateInternetSamples() {
        state.withLock {
            $0.networkGeneration &+= 1
            for key in Array($0.samples.keys) where key.requiresInternet {
                $0.samples[key]?.latencyEWMA = 0; $0.samples[key]?.sampledAt = nil
                $0.samples[key]?.probeMs = nil; $0.samples[key]?.probeAt = nil
                $0.samples[key]?.probeFailed = false; $0.samples[key]?.lastRecoveryUptime = nil
            }
        }
    }
    /// Only capture-start spends a recovery slot; diagnostics never reserve one.
    func reserveRecovery(binding: ASRBackendBinding, uptime: UInt64) -> Bool {
        state.withLock {
            var sample = $0.samples[Key(binding)] ?? Sample()
            if let last = sample.lastRecoveryUptime,
               uptime < last || uptime - last < ASRRouterProbeConfig.recoveryIntervalNanoseconds { return false }
            sample.lastRecoveryUptime = uptime; $0.samples[Key(binding)] = sample
            return true
        }
    }
}
