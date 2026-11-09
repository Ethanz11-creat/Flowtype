import Foundation
import os

/// A transfer returns only after its serial delegate has stopped writing and closed the file.
/// Caller owns the partial's directory and must not mutate it or its sidecar while transfer is active.
final class HFDownloadTransport: @unchecked Sendable {
    typealias ChunkWriter = @Sendable (FileHandle, Data) throws -> Void
    private let configuration: URLSessionConfiguration
    private let credentials: any ASRCredentialStore
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let chunkWriter: ChunkWriter

    init(configuration: URLSessionConfiguration = .ephemeral,
         credentialStore: any ASRCredentialStore = KeychainASRCredentialStore.shared,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         chunkWriter: ChunkWriter? = nil) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        // Request timeout is an idle timeout; large files have no short total transfer deadline.
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        self.configuration = config; credentials = credentialStore; self.sleep = sleep
        self.chunkWriter = chunkWriter ?? { try $0.write(contentsOf: $1) }
    }

    func transfer(file: HFPlannedFile, partialURL: URL, credentialID: String?,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard credentialID == nil || credentialID == "asr.hf.official" else { throw HFDownloadError(code: .auth) }
        let resolveURL = try Self.resolveURL(file)
        guard partialURL.isFileURL, file.sizeBytes > 0 else { throw HFDownloadError(code: .integrity) }
        var validator: String?
        do {
            if FileManager.default.fileExists(atPath: HFDownloadJournal.sidecarURL(for: partialURL).path) {
                if let journal = try? HFDownloadJournal.read(for: partialURL), journal.file == file,
                   journal.credentialID == credentialID, journal.writtenBytes == (try Self.length(partialURL)),
                   journal.writtenBytes >= 0, journal.writtenBytes <= file.sizeBytes {
                    validator = HFDownloadJournal.safeValidator(journal.validator)
                } else { try Self.discard(partialURL) }
            }
        } catch { throw HFDownloadError.disk(error) }
        var rangeRestarted = false
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                var currentURL = resolveURL
                var bearerAllowed = HFMetadataRedirectPolicy.isOfficial(resolveURL)
                var hops = 0
                while true {
                    try Task.checkCancellation()
                    let offset = try Self.length(partialURL)
                    var request = URLRequest(url: currentURL, timeoutInterval: 60)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                    if offset > 0, let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
                    if bearerAllowed, let credentialID {
                        guard let token = try credentials.read(id: credentialID), !token.isEmpty,
                              !token.contains("\r"), !token.contains("\n") else { throw HFDownloadError(code: .auth) }
                        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    }
                    let sink = HFDownloadSink(file: file, partialURL: partialURL, offset: offset, validator: validator,
                                              credentialID: credentialID, progress: progress, writer: chunkWriter)
                    let outcome = try await sink.run(request: request, configuration: configuration)
                    switch outcome {
                    case .redirect(let location):
                        guard hops < 5, let next = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                              Self.safeHTTPS(next) else { throw HFDownloadError(code: .network) }
                        hops += 1; bearerAllowed = bearerAllowed && Self.sameOrigin(currentURL, next) && HFMetadataRedirectPolicy.isOfficial(next)
                        currentURL = next
                    case .rangeUnsatisfied:
                        if (try Self.length(partialURL)) == file.sizeBytes,
                           (try? HFFileVerifier.verify(file: file, at: partialURL)) != nil {
                            try Self.removeSidecar(partialURL); return
                        }
                        throw HFDownloadAttemptError.restartRange
                    case .complete:
                        do { try HFFileVerifier.verify(file: file, at: partialURL) }
                        catch { try? Self.discard(partialURL); throw error }
                        try Self.removeSidecar(partialURL)
                        try Task.checkCancellation()
                        return
                    }
                }
            } catch HFDownloadAttemptError.restartRange {
                try? Self.discard(partialURL); validator = nil
                guard !rangeRestarted, attempt < 2 else { throw HFDownloadError(code: .integrity) }
                rangeRestarted = true
            } catch let failure as HFDownloadAttemptError {
                switch failure {
                case .retry(let error, let delay):
                    guard attempt < 2 else { throw error }
                    try await wait(delay ?? TimeInterval(attempt + 1))
                    validator = try? HFDownloadJournal.read(for: partialURL).validator
                case .expiredURL:
                    // An origin permission failure is permanent. A CDN 401/403 obtains a fresh resolve URL.
                    guard attempt < 2 else { throw HFDownloadError(code: .auth) }
                    try await wait(TimeInterval(attempt + 1))
                    validator = try? HFDownloadJournal.read(for: partialURL).validator
                case .restartRange: preconditionFailure("handled above")
                }
            } catch is CancellationError { throw HFDownloadError(code: .cancelled) }
            catch let error as HFDownloadError {
                if error.code == .integrity { try? Self.discard(partialURL) }
                throw error
            } catch {
                let e = error as NSError
                if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { throw HFDownloadError(code: .cancelled) }
                if Self.transient(error), attempt < 2 {
                    try await wait(TimeInterval(attempt + 1))
                    validator = try? HFDownloadJournal.read(for: partialURL).validator
                } else { throw HFDownloadError.disk(error) }
            }
        }
        throw HFDownloadError(code: .network)
    }
    private func wait(_ seconds: TimeInterval) async throws {
        do { try await sleep(seconds); try Task.checkCancellation() }
        catch is CancellationError { throw HFDownloadError(code: .cancelled) }
    }
    fileprivate static func transient(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed].contains(e.code)
    }
    fileprivate static func safeHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }
    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool { a.scheme == b.scheme && a.host == b.host && (a.port ?? 443) == (b.port ?? 443) }
    private static func resolveURL(_ file: HFPlannedFile) throws -> URL {
        guard safeHTTPS(file.downloadEndpoint), file.downloadEndpoint.query == nil,
              ["", "/"].contains(file.downloadEndpoint.path),
              file.resolvedCommit.count == 40, file.resolvedCommit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              HFRepositoryInput.validPath(file.remotePath),
              (try? HFRepositoryInput.parse(file.source.repoID))?.repoID == file.source.repoID else { throw HFDownloadError(code: .integrity) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let segments = file.source.repoID.components(separatedBy: "/") + ["resolve", file.resolvedCommit] + file.remotePath.components(separatedBy: "/")
        var c = URLComponents(url: file.downloadEndpoint, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        guard let url = c.url else { throw HFDownloadError(code: .integrity) }; return url
    }
    fileprivate static func length(_ url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular, let size = values[.size] as? NSNumber else { throw HFDownloadError(code: .integrity) }
        return size.int64Value
    }
    private static func removeSidecar(_ url: URL) throws {
        let sidecar = HFDownloadJournal.sidecarURL(for: url)
        if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
    }
    private static func discard(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try removeSidecar(url)
    }
}

private enum HFDownloadOutcome { case complete, redirect(String), rangeUnsatisfied }
private enum HFDownloadAttemptError: Error { case restartRange, retry(HFDownloadError, TimeInterval?), expiredURL }

/// File, response state and continuation are confined to the session's serial delegate queue.
private final class HFDownloadSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: HFPlannedFile, partialURL: URL, offset: Int64, originalValidator: String?, credentialID: String?
    private let progress: @Sendable (Int64) -> Void, writer: HFDownloadTransport.ChunkWriter
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var responseEnd: Int64?
    private var validator: String?
    private var outcome: HFDownloadOutcome = .complete
    private var failure: Error?
    private var continuation: CheckedContinuation<HFDownloadOutcome, Error>?
    private struct Control { var task: URLSessionDataTask?; var cancelled = false }
    private let control = OSAllocatedUnfairLock(initialState: Control())

    init(file: HFPlannedFile, partialURL: URL, offset: Int64, validator: String?, credentialID: String?,
         progress: @escaping @Sendable (Int64) -> Void, writer: @escaping HFDownloadTransport.ChunkWriter) {
        self.file = file; self.partialURL = partialURL; self.offset = offset; originalValidator = validator
        self.credentialID = credentialID; self.progress = progress; self.writer = writer
    }
    func run(request: URLRequest, configuration: URLSessionConfiguration) async throws -> HFDownloadOutcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                control.withLock { state in state.task = task; if state.cancelled { task.cancel() }; task.resume() }
            }
        } onCancel: { control.withLock { state in state.cancelled = true; state.task?.cancel() } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Process the redirect as a response; never let URLSession implicitly forward auth.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw HFDownloadError(code: .network) }
            let status = response.statusCode
            if [301, 302, 303, 307, 308].contains(status) {
                guard let location = response.value(forHTTPHeaderField: "Location") else { throw HFDownloadError(code: .network) }
                outcome = .redirect(location); completionHandler(.cancel); return
            }
            if status == 416 { outcome = .rangeUnsatisfied; completionHandler(.cancel); return }
            if status == 401 || status == 403 {
                if response.url?.host != file.downloadEndpoint.host { throw HFDownloadAttemptError.expiredURL }
                throw HFDownloadError(code: .auth)
            }
            if status == 429 || (500...599).contains(status) {
                let delay = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
                let code: HFDownloadError.Code = status == 429 ? .rateLimit : .network
                if let delay, delay > 30 { throw HFDownloadError(code: code, retryAfter: delay, requiresPause: true) }
                throw HFDownloadAttemptError.retry(.init(code: code, retryAfter: delay), delay)
            }
            guard status == 200 || status == 206 else { throw HFDownloadError(code: .network) }
            guard response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else { throw HFDownloadError(code: .integrity) }
            if response.mimeType?.lowercased() == "text/html" { throw HFDownloadError(code: .integrity) }
            validator = HFDownloadJournal.safeValidator(response.value(forHTTPHeaderField: "ETag"))
            if status == 206 {
                guard let range = Self.range(response.value(forHTTPHeaderField: "Content-Range")),
                      range.start == offset, range.total == file.sizeBytes else { throw HFDownloadAttemptError.restartRange }
                responseEnd = range.end + 1
                if let originalValidator, validator != originalValidator { throw HFDownloadError(code: .integrity) }
                written = offset
            } else { written = 0; responseEnd = file.sizeBytes }
            if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
               length != (responseEnd! - written) { throw HFDownloadError(code: .integrity) }
            if !FileManager.default.fileExists(atPath: partialURL.path) {
                guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else { throw HFDownloadError(code: .network) }
            }
            _ = try HFDownloadTransport.length(partialURL)
            handle = try FileHandle(forWritingTo: partialURL)
            if status == 200 { try handle!.truncate(atOffset: 0) }
            try handle!.seek(toOffset: UInt64(written))
            try journal()
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle, !control.withLock({ $0.cancelled }) else { return }
        do {
            var start = data.startIndex
            while start < data.endIndex {
                if control.withLock({ $0.cancelled }) { return }
                let end = min(start + HFFileVerifier.chunkBytes, data.endIndex)
                let chunk = data.subdata(in: start..<end)
                guard written <= file.sizeBytes - Int64(chunk.count), written + Int64(chunk.count) <= (responseEnd ?? 0) else { throw HFDownloadError(code: .integrity) }
                try writer(handle, chunk); written += Int64(chunk.count)
                try journal()
                if !control.withLock({ $0.cancelled }) { progress(written) }
                start = end
            }
        } catch { failure = (error as? HFDownloadError) ?? HFDownloadError.disk(error); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.synchronize(); try handle?.close() }
        catch { if failure == nil { failure = HFDownloadError.disk(error) } }
        handle = nil
        let cancelled = control.withLock { state in state.task = nil; return state.cancelled }
        let result: Result<HFDownloadOutcome, Error>
        if cancelled { result = .failure(HFDownloadError(code: .cancelled)) }
        else if let failure { result = .failure(failure) }
        else {
            switch outcome {
            case .complete:
                if let error { result = .failure(error) }
                else if written != responseEnd { result = .failure(HFDownloadError(code: .integrity)) }
                else { result = .success(outcome) }
            case .redirect, .rangeUnsatisfied: result = .success(outcome)
            }
        }
        let completion = continuation; continuation = nil
        session.finishTasksAndInvalidate()
        // All disk writes and user callbacks are finished before releasing the caller's ownership slot.
        completion?.resume(with: result)
    }
    private func journal() throws {
        try HFDownloadJournal(file: file, writtenBytes: written, validator: validator, credentialID: credentialID).write(for: partialURL)
    }
    private static func range(_ header: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), let total = Int64(parts[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
