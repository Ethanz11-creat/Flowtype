import Foundation
import AppKit

/// Packaged applications never consult SwiftPM's development resource search paths.
enum AppResources {
    static func bundle(in application: Bundle) throws -> Bundle {
        guard application.bundleURL.pathExtension.lowercased() == "app" else { return Bundle.module }
        let url = application.bundleURL.appendingPathComponent("Contents/Resources/FlowType_FlowType.bundle")
        try requireInsideApp(url, application: application)
        guard let bundle = Bundle(url: url) else { throw ArtifactCheckError.failure(.resourceMissing) }
        return bundle
    }

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        try? resourceURL(name, ext, in: .main)
    }

    private static func resourceURL(_ name: String, _ ext: String, in application: Bundle) throws -> URL {
        let resources = try bundle(in: application)
        // Check the intended path before Bundle lookup so even a dangling escaped symlink is rejected.
        let intended = (resources.resourceURL ?? resources.bundleURL).appendingPathComponent(name + "." + ext)
        if application.bundleURL.pathExtension.lowercased() == "app" {
            try requireInsideApp(intended, application: application)
        }
        guard let url = resources.url(forResource: name, withExtension: ext) else {
            throw ArtifactCheckError.failure(.resourceMissing)
        }
        if application.bundleURL.pathExtension.lowercased() == "app" {
            try requireInsideApp(url, application: application)
        }
        return url
    }

    static func requireInsideApp(_ url: URL, application: Bundle) throws {
        let app = try canonicalURL(application.bundleURL).pathComponents
        let resolved = try canonicalURL(url).pathComponents
        guard resolved.count > app.count, Array(resolved.prefix(app.count)) == app else {
            throw ArtifactCheckError.failure(.resourceOutsideBundle)
        }
    }

    // URL.resolvingSymlinksInPath can leave an ancestor unresolved when the leaf is absent.
    // Resolve each segment, including dangling links, before comparing directory boundaries.
    private static func canonicalURL(_ url: URL) throws -> URL {
        var pending = url.path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." { continue }
            if part == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                links += 1
                guard links <= 40 else { throw ArtifactCheckError.failure(.resourceOutsideBundle) }
                if destination.hasPrefix("/") { resolved.removeAll() }
                pending = destination.split(separator: "/").map(String.init) + pending
            } else { resolved.append(part) }
        }
        return URL(fileURLWithPath: "/" + resolved.joined(separator: "/"))
    }

    /// Strict artifact checks intentionally do not use the postprocessor's ordinary built-in fallbacks.
    /// Returns the standard SwiftPM MLX library location; loading belongs to the next stage.
    static func validateArtifactResources(in application: Bundle) throws -> URL {
        guard application.bundleURL.pathExtension.lowercased() == "app" else {
            throw ArtifactCheckError.failure(.resourceMissing)
        }
        let termsURL = try resourceURL("tech_terms", "json", in: application)
        let fillersURL = try resourceURL("filler_words", "json", in: application)
        let iconURL = try resourceURL("status_bar_icon", "png", in: application)
        do {
            let terms = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: termsURL))
            let fillers = try JSONDecoder().decode([String].self, from: Data(contentsOf: fillersURL))
            func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !terms.isEmpty, terms.allSatisfy({ nonempty($0.key) && nonempty($0.value) }),
                  !fillers.isEmpty, fillers.allSatisfy(nonempty),
                  let image = NSImage(contentsOf: iconURL), !image.representations.isEmpty else {
                throw ArtifactCheckError.failure(.resourceMalformed)
            }
        } catch { throw ArtifactCheckError.failure(.resourceMalformed) }
        let metal = application.bundleURL.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib")
        try requireInsideApp(metal, application: application)
        return metal
    }
}
