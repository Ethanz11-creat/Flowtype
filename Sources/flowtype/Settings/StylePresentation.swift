import Foundation
import Combine

/// Describes exactly the pack already resolved by StylePackStore.activePack.
enum StylePresentation {
    static func effectiveSource(pack: StylePack?, configuration: Configuration) -> String {
        guard let pack else { return "高级默认提示词（配置）" }
        return pack.active && pack.enabled ? "活动风格：\(pack.name)" : "内置回退：\(pack.name)"
    }
}

@MainActor
final class StylePageModel: ObservableObject {
    @Published var editingPack: StylePack?
    @Published var newName = ""
    @Published var newPrompt = ""
    @Published var importExportError: String?
    @Published private(set) var navigationRequestID: UUID?
    @Published private(set) var selectedID: String?
    private let store: StylePackStore

    init(store: StylePackStore) { self.store = store }

    func consume(_ request: NavigationRequest?) {
        guard let request, request.id != navigationRequestID,
              case .style(let id) = request.destination else { return }
        navigationRequestID = request.id
        selectedID = id.flatMap { target in store.packs.first { $0.id == target }?.id }
    }

    func importData(_ data: Data) {
        do { try store.importFromJSON(data); importExportError = nil }
        catch { importExportError = "导入失败：\(error.localizedDescription)" }
    }
}
