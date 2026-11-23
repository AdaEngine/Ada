@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorInspectorSidebar {
    func locomotionFields(_ component: EditorInspectorSidebarViewModel.ComponentSection) -> some View {
        let direction = component.fields.first { $0.field.key == "configuration.facingMode" }?.value
        let catalog = viewModel.selectedEntity?.locomotion?.catalog ?? .unavailable
        return VStack(alignment: .leading, spacing: 8) {
            if let state = viewModel.selectedEntity?.locomotion {
                if !state.hasController {
                    locomotionIssue(L10n.tr("Add a 3D Character Controller to this entity."))
                }
                if state.hasPlaybackConflict {
                    locomotionIssue(L10n.tr("Remove the animation graph or manual playback to use locomotion."))
                }
            }

            ForEach(EditorLocomotionGroup.allCases, id: \.id) { group in
                let collapseByDefault = group == .directional && direction != "keepFacing"
                let isToggled = collapsedFieldGroups[component.typeName]?.contains(group.rawValue) == true
                let row = EditorInspectorFieldLayout.Row(
                    id: "group:\(group.rawValue)", level: 0, groupPath: [group.rawValue], title: group.rawValue
                )
                fieldGroupHeader(row, namespace: component.typeName, collapsedByDefault: collapseByDefault)
                if isToggled == collapseByDefault {
                    let fields = component.fields.filter { $0.field.groupPath == [group.rawValue] }
                    locomotionGroupFields(fields, group: group, catalog: catalog)
                }
            }
        }
        .onChange(of: direction) { _, _ in
            collapsedFieldGroups[component.typeName]?.remove(EditorLocomotionGroup.directional.rawValue)
        }
        .id(viewModel.selectedEntity?.editorID)
    }

    @ViewBuilder
    private func locomotionGroupFields(
        _ fields: [EditorInspectorSidebarViewModel.ComponentField],
        group: EditorLocomotionGroup,
        catalog: EditorLocomotionInspectorState.Catalog
    ) -> some View {
        if group == .facing {
            ForEach(fields, id: \.field.key) { item in
                locomotionSetting(item)
            }
        } else {
            if group == .clips {
                switch catalog {
                case .loading:
                    fieldLabel("Loading model clips…")
                case .unavailable:
                    fieldLabel("Assign a skinned 3D model to choose clips.")
                case let .failed(reason):
                    locomotionIssue(L10n.text("Check the 3D model settings. \(reason)"))
                case let .ready(names, ambiguous):
                    if names.isEmpty && ambiguous.isEmpty { fieldLabel("The model has no animation clips.") }
                }
            }

            ForEach(Array(stride(from: 0, to: fields.count, by: 2)), id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    locomotionGroupedField(fields[index], group: group, catalog: catalog)
                    if fields.indices.contains(index + 1) {
                        locomotionGroupedField(fields[index + 1], group: group, catalog: catalog)
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func locomotionGroupedField(
        _ item: EditorInspectorSidebarViewModel.ComponentField,
        group: EditorLocomotionGroup,
        catalog: EditorLocomotionInspectorState.Catalog
    ) -> some View {
        if group == .timing {
            EditorLocomotionNumberField(sidebar: self, item: item)
        } else {
            locomotionClip(item, catalog: catalog, isOptional: group == .directional)
        }
    }

    @ViewBuilder
    private func locomotionSetting(_ item: EditorInspectorSidebarViewModel.ComponentField) -> some View {
        let binding = viewModel.componentFieldBinding(typeName: item.typeName, field: item.field)
        let id = "AdaEditor.Inspector.Locomotion.\(item.field.key)"
        if case let .enumeration(cases) = item.field.kind {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(item.field.label)
                let labels = [
                    "turnToMovement": "Turn to movement", "keepFacing": "Keep facing",
                    "positiveZ": "+Z", "positiveX": "+X", "negativeZ": "−Z", "negativeX": "−X",
                ]
                EditorEnumField(cases: cases, selection: binding, accessibilityID: id, labels: labels)
            }
        } else {
            HStack(spacing: 8) {
                fieldLabel(item.field.label)
                boolField(text: binding)
                    .frame(width: 95)
                    .accessibilityIdentifier(id)
            }
        }
    }

    private func locomotionClip(
        _ item: EditorInspectorSidebarViewModel.ComponentField,
        catalog: EditorLocomotionInspectorState.Catalog,
        isOptional: Bool
    ) -> some View {
        let id = "AdaEditor.Inspector.Locomotion.\(item.field.key)"
        let binding = viewModel.componentFieldBinding(typeName: item.typeName, field: item.field)
        let value = binding.wrappedValue
        let names: [String]
        let issue: String?
        if case let .ready(available, ambiguous) = catalog {
            names = available
            if ambiguous.contains(value) {
                issue = L10n.text("More than one clip is named \(value).")
            } else if !value.isEmpty && !names.contains(value) {
                issue = L10n.text("Clip \(value) is missing.")
            } else if value.isEmpty && !isOptional {
                issue = L10n.tr("Select a clip.")
            } else {
                issue = nil
            }
        } else {
            names = []
            issue = nil
        }
        let choices = isOptional ? [""] + names : names
        let emptyLabel = L10n.tr(isOptional ? "Use forward clip" : "Select a clip.")
        let ownerID = viewModel.selectedEntity?.editorID
        let viewportID = viewModel.sceneViewportActionOwner
        let selection = Binding(get: { binding.wrappedValue }, set: { name in
            guard viewModel.sceneViewportActionOwner == viewportID, viewModel.selectedEntity?.editorID == ownerID else {
                return
            }
            if isOptional && name.isEmpty {
                binding.wrappedValue = name
            } else if case let .ready(currentNames, _)? = viewModel.selectedEntity?.locomotion?.catalog, currentNames.contains(name) {
                binding.wrappedValue = name
            }
        })
        return VStack(alignment: .leading, spacing: 4) {
            fieldLabel(item.field.label)
            EditorEnumField(
                cases: choices,
                selection: selection,
                accessibilityID: id,
                labels: ["": emptyLabel],
                localizesValues: false,
                compact: true
            )
                .disabled(choices.isEmpty)
                .overlay {
                    if issue != nil {
                        RoundedRectangleShape(cornerRadius: 6).stroke(Color.red.opacity(0.85), lineWidth: 1).allowsHitTesting(false)
                    }
                }
            if let issue { locomotionIssue(issue) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func locomotionIssue(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\u{E000}").font(AdaEditorMaterialSymbolFont.font(size: 13))
            Text(message).font(.system(size: 10))
        }
        .foregroundColor(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EditorLocomotionNumberField: View {
    let sidebar: EditorInspectorSidebar
    let item: EditorInspectorSidebarViewModel.ComponentField
    @State private var draft: String?

    var body: some View {
        let binding = sidebar.viewModel.componentFieldBinding(typeName: item.typeName, field: item.field)
        let accepted = draft.flatMap {
            item.field.numberRule?.value($0.replacingOccurrences(of: ",", with: "."))
        }
        let isInvalid = draft != nil && accepted == nil
        return VStack(alignment: .leading, spacing: 4) {
            sidebar.fieldLabel(item.field.label)
            sidebar.editorTextField(
                text: Binding(get: { draft ?? binding.wrappedValue }, set: { draft = $0 }),
                onSubmit: {
                    guard let draft, let accepted = item.field.numberRule?.value(draft.replacingOccurrences(of: ",", with: ".")) else {
                        return
                    }
                    self.draft = nil
                    binding.wrappedValue = String(accepted)
                },
                hasError: isInvalid
            )
            .accessibilityIdentifier("AdaEditor.Inspector.Locomotion.\(item.field.key)")

            let hint = isInvalid
                ? L10n.tr(item.field.numberRule == .nonnegativeDouble ? "Enter zero or a positive number." : "Enter a positive number.")
                : L10n.tr("Press Enter to apply.")
            Text(hint)
                .font(.system(size: 10))
                .foregroundColor(isInvalid ? .red : sidebar.theme.editorColors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28, alignment: .topLeading)
                .opacity(draft == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: item.value) { _, _ in draft = nil }
    }
}
