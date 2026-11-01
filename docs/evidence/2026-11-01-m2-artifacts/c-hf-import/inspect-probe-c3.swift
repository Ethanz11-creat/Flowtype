import Foundation
@main
struct InspectProbe {
    static func main() {
        print("UTC \(ISO8601DateFormatter().string(from: Date()))")
        do {
            let model = try ASRModelInspector.inspect(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
            print("STATIC PASS engine=\(model.engine.rawValue) variant=\(model.variant) bits=\(model.bits ?? 0) sizeBytes=\(model.sizeBytes)")
            print("fingerprint=\(model.fileFingerprint)")
            print("reservationBytes=\(model.minimumResidentBytes.map(String.init) ?? "unknown")")
        } catch let error as ASRModelInspectionError {
            print("STATIC FAIL code=\(error.code.rawValue) detail=\(error.detail)")
        } catch { print("STATIC FAIL unclassified") }
    }
}
