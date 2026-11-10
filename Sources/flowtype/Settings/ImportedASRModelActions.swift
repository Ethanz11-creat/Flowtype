import Foundation
import Combine

/// Owns only inspection previews. QwenModelState remains the sole runtime/selection coordinator.
@MainActor
final class ImportedASRModelActions: ObservableObject {
    struct Preview {
        let id = UUID()
        let model: ImportedASRModel
        let assessment: LocalModelHardwareAssessment
        let replacingID: UUID?
    }
    @Published private(set) var preview: Preview?
    @Published private(set) var isInspecting = false
    @Published private(set) var message: String?
    private let coordinator: QwenModelState
    private let configuration: () -> Configuration
    private let inspect: @Sendable (URL) async throws -> ImportedASRModel
    private let assess: (ImportedASRModel) -> LocalModelHardwareAssessment
    private var inspectionID: UUID?
    private var inspectionTask: Task<Void, Never>?

    init(coordinator: QwenModelState, configuration: @escaping () -> Configuration,
         inspect: @escaping @Sendable (URL) async throws -> ImportedASRModel = { directory in
             let worker = Task.detached(priority: .userInitiated) {
                 try Task.checkCancellation()
                 return try ASRModelInspector.inspect(directory: directory)
             }
             return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
         }, assess: ((ImportedASRModel) -> LocalModelHardwareAssessment)? = nil) {
        self.coordinator = coordinator; self.configuration = configuration; self.inspect = inspect
        self.assess = assess ?? { LocalModelHardwareAssessment.current(model: $0, activeModelBytes: coordinator.activeLease?.minimumResidentBytes) }
    }

    /// Reserve ownership synchronously, before a queued action can race with another click/removal.
    @discardableResult
    func stage(directory: URL, replacing id: UUID? = nil) -> Task<Void, Never>? {
        guard coordinator.operationID == nil else { return nil }
        cancelInspection()
        if let id, !configuration().importedASRModels.contains(where: { $0.id == id }) {
            message = "此模型记录已移除，请重新导入。"; return nil
        }
        let token = UUID(); inspectionID = token; isInspecting = true; message = nil
        let inspect = self.inspect
        let task = Task {
            do {
                var model = try await inspect(directory)
                try Task.checkCancellation()
                guard inspectionID == token else { return }
                if let id {
                    guard let existing = configuration().importedASRModels.first(where: { $0.id == id }) else {
                        throw ASRModelInspectionError(code: .unreadable, detail: "此模型记录已移除，请重新导入。")
                    }
                    guard !relocationConflicts(directory: model.directory, id: id) else {
                        throw ASRModelInspectionError(code: .invalidMetadata, detail: "此目录属于另一条模型记录，请在模型库中选择该记录。")
                    }
                    model.id = id; model.name = existing.name
                } else { model = LocalModelLibrary.canonicalizing(model, in: configuration()) }
                preview = .init(model: model, assessment: assess(model), replacingID: id ?? configuration().importedASRModels.first(where: { $0.id == model.id })?.id)
            } catch is CancellationError { /* Cancelled inspection never publishes a preview. */ }
            catch {
                guard inspectionID == token else { return }
                message = (error as? ASRModelInspectionError)?.detail ?? error.localizedDescription
            }
            guard inspectionID == token else { return }
            isInspecting = false; inspectionID = nil; inspectionTask = nil
        }
        inspectionTask = task
        return task
    }

    @discardableResult
    func stageExisting(id: UUID) -> Task<Void, Never>? {
        guard let model = configuration().importedASRModels.first(where: { $0.id == id }) else {
            cancelInspection(); message = "此模型记录已移除，请重新导入。"; return nil
        }
        return stage(directory: model.directory, replacing: id)
    }

    func cancelInspection() {
        inspectionID = nil; inspectionTask?.cancel(); inspectionTask = nil
        isInspecting = false; preview = nil; message = nil
    }

    func loadPreview() async {
        guard let preview, !isInspecting, coordinator.operationID == nil,
              preview.assessment.compatibility != .incompatible else { return }
        if let id = preview.replacingID, !configuration().importedASRModels.contains(where: { $0.id == id }) {
            cancelInspection(); message = "此模型记录已移除，请重新导入。"; return
        }
        if let id = preview.replacingID, relocationConflicts(directory: preview.model.directory, id: id) {
            cancelInspection(); message = "此目录已属于另一条模型记录，请重新选择。"; return
        }
        message = nil
        do {
            // Reinspection, resource admission, UUID resolution and the only save occur inside this coordinator.
            try await coordinator.useImportedModel(preview.model)
            guard self.preview?.id == preview.id else { return }
            self.preview = nil
        } catch is CancellationError {
            guard self.preview?.id == preview.id else { return }
            message = "已取消加载，之前可用的模型和选择保持不变。"
        } catch {
            guard self.preview?.id == preview.id else { return }
            message = coordinator.importFailureDetail ?? "加载失败，之前可用的模型和选择保持不变。可检查文件、重新定位后重试。"
        }
    }

    private func relocationConflicts(directory: URL, id: UUID) -> Bool {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath()
        return configuration().importedASRModels.contains {
            $0.id != id && $0.directory.standardizedFileURL.resolvingSymlinksInPath() == path
        }
    }

    func remove(id: UUID) {
        guard coordinator.operationID == nil else { return }
        cancelInspection()
        if configuration().installedASRModels.contains(where: { $0.importedModelID == id && $0.ownership == .managed }) {
            Task {
                do { try await coordinator.removeModelRecord(id: id) }
                catch { message = "请先解除模型选择并结束使用它的会话，再移除记录。" }
            }
        } else if !coordinator.removeImportedModel(id: id) {
            message = "请先解除模型选择并结束使用它的会话，再移除记录。"
        }
    }
}
