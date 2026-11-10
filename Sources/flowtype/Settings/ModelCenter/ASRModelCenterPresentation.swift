import Foundation

enum ASRModelCenterStatus: Equatable {
    case notInstalled, queued, downloading(progress: Double), paused, verifying
    case installedUntested, testing, previouslyValidated, ready
    case unavailable(reason: String), failed(reason: String)
}

struct ASRModelCenterRow: Identifiable, Equatable {
    let id: ASRBackendID
    let title: String
    let subtitle: String
    let location: ASRBackendLocation
    let status: ASRModelCenterStatus
    let isPrimary: Bool
    let isFallback: Bool
}

/// Value projection only: never scans files, opens a connection, or owns a runtime.
enum ASRModelCenterPresentation {
    static func installationStatus(_ snapshot: ModelInstallSnapshot) -> ASRModelCenterStatus {
        switch snapshot.state {
        case .queued: .queued
        case .downloading:
            .downloading(progress: snapshot.plan.totalBytes > 0
                ? min(1, max(0, Double(snapshot.receivedBytes) / Double(snapshot.plan.totalBytes))) : 0)
        case .paused: .paused
        case .verifying: .verifying
        case .installed: .installedUntested
        case .failed: .failed(reason: snapshot.errorCode ?? "安装失败，请查看安装任务。")
        case .cancelled: .paused
        }
    }

    static func nativeID(for model: ImportedASRModel, records: [ASRInstalledModelRecord]) -> ASRBackendID {
        // Only B6's actual validated association can fold an adopted legacy row into its preset.
        let associations = Set(records.filter { $0.importedModelID == model.id }.compactMap(\.legacyPresetID))
        if associations.count == 1, let preset = associations.first {
            return .init(rawValue: "native:preset:" + preset)
        }
        return .init(rawValue: "native:import:" + model.id.uuidString)
    }
}
