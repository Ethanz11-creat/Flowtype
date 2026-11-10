import SwiftUI
import AppKit

struct LocalModelPicker: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var modelState: QwenModelState
    @ObservedObject var downloader: ModelDownloader
    @ObservedObject var importedActions: ImportedASRModelActions
    @State private var deletionError: String?

    func selectPreset(_ preset: ModelPreset?, automatic: Bool = false) async {
        await modelState.selectPreset(preset, automatic: automatic)
    }

    func cancelPreparation() {
        if let current = downloader.currentDownload, downloader.isDownloading(preset: current.preset) {
            downloader.cancelDownload()
        } else { modelState.cancel() }
    }

    var importedModels: ImportedASRModelList {
        ImportedASRModelList(store: store, coordinator: modelState, actions: importedActions)
    }

    var selectionPresentation: LocalModelSelectionPresentation {
        .make(config: store.current, coordinator: modelState)
    }

    private var currentTier: HardwareTier { HardwareProfiler.currentTier() }
    var recommendedPreset: ModelPreset { ModelPreset.recommendedModel(for: currentTier) }

    var navigation: SettingsNavigation? = nil

    // Compatibility presentation delegates to the shared host; lifecycle helpers above
    // remain available to isolated legacy fixtures, never as a second set of UI actions.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("离线模型的获取、测试与选择已移至模型中心。")
                .foregroundStyle(.secondary)
            Button("打开离线模型") { navigation?.navigate(to: .settings(.speech, .localModels)) }
                .disabled(navigation == nil)
        }
    }
}
