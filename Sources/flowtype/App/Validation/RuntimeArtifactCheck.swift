import Foundation
import Metal
import MLX

enum ArtifactCheckError: Error { case failure(ValidationFailureCode) }

/// All hardware work is lazy and confined to the live artifact entry point.
@MainActor
struct ArtifactCheckDependencies {
    let resolveResources: () throws -> URL
    let loadMetalLibrary: (URL) throws -> Void
    let mlxOperation: () throws -> [Int32]

    static func live(application: Bundle) -> ArtifactCheckDependencies {
        ArtifactCheckDependencies(resolveResources: {
            try AppResources.validateArtifactResources(in: application)
        }, loadMetalLibrary: { url in
            guard let device = MTLCreateSystemDefaultDevice() else { throw ArtifactCheckError.failure(.metalUnavailable) }
            do { _ = try device.makeLibrary(URL: url) }
            catch { throw ArtifactCheckError.failure(.metalLibraryInvalid) }
        }, mlxOperation: {
            do {
                return try MLX.withError { error in
                    let input = MLXArray([Int32(1), 2])
                    try error.check()
                    let output = MLX.add(input, Int32(1), stream: .gpu)
                    try error.check()
                    MLX.eval(output)
                    try error.check()
                    let values = output.asArray(Int32.self)
                    try error.check()
                    return values
                }
            } catch { throw ArtifactCheckError.failure(.mlxOperationFailed) }
        })
    }
}

struct ArtifactReport: Codable, Sendable {
    let schemaVersion: Int
    let mode: String
    let ok: Bool
    let role: ProcessRole
    let runID: String
    let buildInfo: BuildIdentity
    let durationMs: Int
    let failureCode: ValidationFailureCode?
    let appResources: Bool
    let metalLibrary: Bool
    let mlxOperation: Bool
    let resolvedInsideApp: Bool
    var exitCode: Int32 { ok ? 0 : 1 }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode, ok, role, runID, buildInfo, durationMs, failureCode
        case appResources, metalLibrary, mlxOperation, resolvedInsideApp
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(mode, forKey: .mode)
        try c.encode(ok, forKey: .ok); try c.encode(role, forKey: .role); try c.encode(runID, forKey: .runID)
        try c.encode(buildInfo, forKey: .buildInfo); try c.encode(durationMs, forKey: .durationMs)
        try c.encode(failureCode, forKey: .failureCode); try c.encode(appResources, forKey: .appResources)
        try c.encode(metalLibrary, forKey: .metalLibrary); try c.encode(mlxOperation, forKey: .mlxOperation)
        try c.encode(resolvedInsideApp, forKey: .resolvedInsideApp)
    }
}

@MainActor
enum RuntimeArtifactCheck {
    static func run(context: RuntimeContext) async -> ArtifactReport {
        await run(context: context, identity: AppLogger.identity, dependencies: .live(application: .main))
    }

    static func run(context: RuntimeContext, identity: BuildIdentity, dependencies: ArtifactCheckDependencies) async -> ArtifactReport {
        let started = DispatchTime.now().uptimeNanoseconds
        var resources = false, metal = false, mlx = false, inside = false
        func report(_ failure: ValidationFailureCode?) -> ArtifactReport {
            ArtifactReport(schemaVersion: 1, mode: "artifact", ok: failure == nil, role: context.role,
                runID: context.runID.uuidString, buildInfo: identity,
                durationMs: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000), failureCode: failure,
                appResources: resources, metalLibrary: metal, mlxOperation: mlx, resolvedInsideApp: inside)
        }
        guard context.role == .smokeTest, context.mode == .artifact else { return report(.startupFailed) }
        guard identity.origin == .packaged, let metadata = identity.metadata, !metadata.dirty,
              identity.failureCode == nil else { return report(.invalidBuildInfo) }
        do {
            let libraryURL = try dependencies.resolveResources()
            resources = true; inside = true
            try dependencies.loadMetalLibrary(libraryURL)
            metal = true
            guard try dependencies.mlxOperation() == [2, 3] else { return report(.mlxOperationFailed) }
            mlx = true
            return report(nil)
        } catch let ArtifactCheckError.failure(code) { return report(code) }
        catch { return report(.unexpectedFailure) }
    }
}
