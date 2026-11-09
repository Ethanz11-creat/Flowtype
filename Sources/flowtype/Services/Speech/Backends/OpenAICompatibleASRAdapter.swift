import Foundation

struct OpenAICompatibleASRAdapter: ASRServiceAdapter {
    let protocolKind = ASRServiceProtocol.openAICompatible
    var session: URLSession? = nil
    var resolver: LocalASRServiceEndpoint.Resolver = LocalASRServiceEndpoint.resolve

    func makeProvider(profile: LocalASRServiceProfile, credential: String?) throws -> any ASRProvider {
        guard profile.protocolKind == protocolKind else { throw ASRServiceAdapterError.unsupportedProtocol }
        return try LocalServiceASRProvider(profile: profile, credential: credential, session: session, resolver: resolver)
    }
}
