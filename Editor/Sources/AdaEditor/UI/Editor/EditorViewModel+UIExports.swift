@_spi(AdaEngine) import AdaEngine

extension EditorViewModel {
    func refreshUIExports() {
        guard let projectURL else {
            return
        }
        workbench.uiExportTask?.cancel()
        let packageModel = self.packageModel
        workbench.uiExportTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let catalog = try await workbench.uiExportLoader.load(projectURL: projectURL, packageModel: packageModel, builder: previewBuilder)
                guard !Task.isCancelled, self.projectURL == projectURL else {
                    return
                }
                guard workbench.uiCatalog.generation != catalog.generation else {
                    return
                }
                workbench.uiCatalog = catalog
                workbench.uiCatalogError = nil
                for model in workbench.uiSceneModels.values {
                    model.install(catalog: catalog)
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                workbench.uiCatalogError = error.localizedDescription
                for model in workbench.uiSceneModels.values { model.error = error.localizedDescription }
            }
        }
    }
}
