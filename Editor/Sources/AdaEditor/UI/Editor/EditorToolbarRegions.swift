@_spi(AdaEngine) import AdaEngine

struct EditorTopToolbarRegion: View {
    let viewModel: EditorViewModel
    let projectSwitcher: EditorProjectSwitcherViewModel
    let isRunDestinationMenuPresented: Bool
    let onToggleRunDestinationMenu: () -> Void
    let onToggleProjectSwitcher: () -> Void

    var body: some View {
        EditorTopToolbar(
            project: viewModel.project,
            isProjectSwitcherPresented: projectSwitcher.isPresented,
            isRunDestinationMenuPresented: isRunDestinationMenuPresented,
            viewModel: viewModel.toolbar,
            runDestination: viewModel.selectedRunDestination,
            isRunEnabled: canRun,
            isStopEnabled: viewModel.isProjectRunning,
            onToggleRunDestinationMenu: onToggleRunDestinationMenu,
            onToggleProjectSwitcher: onToggleProjectSwitcher,
            onRun: viewModel.runFromToolbar,
            onStop: viewModel.stopFromToolbar,
            onDebug: debugAction
        )
    }
    private var canRun: Bool {
        if viewModel.selectedRunDestination == .player {
            return !viewModel.playerSession.isBusy
        }
        return !viewModel.isProjectRunning
    }

    private var debugAction: (() -> Void)? {
        guard viewModel.selectedRunDestination != .player else {
            return nil
        }
        return { viewModel.debugSelectedTarget() }
    }
}

struct EditorRunDestinationOverlay: View {
    let isPresented: Bool
    let selectedDestination: EditorRunDestination
    let toolbarHeight: Float
    let onDismiss: () -> Void
    let onSelect: (EditorRunDestination) -> Void

    var body: some View {
        if isPresented {
            ZStack(anchor: .topTrailing) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(perform: onDismiss)

                EditorRunDestinationMenu(
                    selectedDestination: selectedDestination,
                    onSelect: { destination in
                        onDismiss()
                        onSelect(destination)
                    }
                )
                .offset(
                    x: -EditorRunDestinationMenuLayout.trailingOffset,
                    y: EditorRunDestinationMenuLayout.topOffset(toolbarHeight: toolbarHeight)
                )
            }
            .zIndex(30)
        }
    }
}
