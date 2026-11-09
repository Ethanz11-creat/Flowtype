import Foundation

struct WhisperCppASRAdapter: ASRServiceAdapter {
    let protocolKind = ASRServiceProtocol.whisperCpp
    var session: URLSession? = nil
    var resolver: LocalASRServiceEndpoint.Resolver = LocalASRServiceEndpoint.resolve

    func makeProvider(profile: LocalASRServiceProfile, credential: String?) throws -> any ASRProvider {
        guard profile.protocolKind == protocolKind else { throw ASRServiceAdapterError.unsupportedProtocol }
        return try LocalServiceASRProvider(profile: profile, credential: credential, session: session, resolver: resolver)
    }
}
