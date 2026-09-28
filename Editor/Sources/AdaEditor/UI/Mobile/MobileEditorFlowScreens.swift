#if os(iOS)
@_spi(AdaEngine) import AdaEngine

struct MobileEditorPreviewScreen: View {
    @Environment(\.theme) private var theme
    @Binding var changeRequest: String
    @Binding var isMarkingScene: Bool
    let showReview: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Foxwood")
                            .font(MobileEditorFont.font(size: 27))
                            .foregroundColor(theme.editorColors.text)
                        Text("Demo game preview")
                            .font(MobileEditorFont.font(size: 12))
                            .foregroundColor(theme.editorColors.muted)
                    }
                    Spacer()
                    Text("PREVIEW")
                        .font(MobileEditorFont.font(size: 10))
                        .foregroundColor(theme.editorColors.blue)
                }

                ZStack(anchor: .topLeading) {
                    MobileEditorForestImage(height: 230)
                    if isMarkingScene {
                        Text("Spot marked for a change")
                            .font(MobileEditorFont.font(size: 12))
                            .foregroundColor(.white)
                            .padding(9)
                            .background(RoundedRectangleShape(cornerRadius: 9).fill(theme.editorColors.purple.opacity(0.85)))
                            .padding(12)
                    }
                }
                .accessibilityIdentifier("AdaEditor.Mobile.GamePreview")

                Button {
                    isMarkingScene.toggle()
                } label: {
                    Text(isMarkingScene ? "Remove marker" : "Mark a spot in the scene")
                        .font(MobileEditorFont.font(size: 14))
                        .foregroundColor(isMarkingScene ? theme.editorColors.purple : theme.editorColors.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 45)
                        .background(RoundedRectangleShape(cornerRadius: 13).fill(theme.editorColors.surface))
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.MarkScene")

                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 9) {
                            Text("AI")
                                .foregroundColor(theme.editorColors.purple)
                            Text("The agent created the first level")
                                .font(MobileEditorFont.font(size: 15))
                                .foregroundColor(theme.editorColors.text)
                        }
                        TextField("Ask for a change…", text: _changeRequest)
                            .font(MobileEditorFont.font(size: 14))
                            .textFieldStyle(PlainTextFieldStyle())
                            .foregroundColor(theme.editorColors.text)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(RoundedRectangleShape(cornerRadius: 10).fill(theme.editorColors.surfaceElevated))
                            .accessibilityIdentifier("AdaEditor.Mobile.ChangeRequest")
                        Button(action: showReview) {
                            HStack {
                                Text("Review an example change")
                                    .font(MobileEditorFont.font(size: 14))
                                Spacer()
                                Text("\u{E5CC}")
                                    .font(AdaEditorMaterialSymbolFont.font(size: 16))
                            }
                            .foregroundColor(theme.editorColors.purple)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Mobile.ShowReview")
                    }
                    .padding(17)
                }

                Text("This demo scene is static. Notes are not sent to an agent yet.")
                    .font(MobileEditorFont.font(size: 12))
                    .foregroundColor(theme.editorColors.muted)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(theme.editorColors.background)
    }
}

struct MobileEditorReviewScreen: View {
    @Environment(\.theme) private var theme
    @Binding var accepted: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                MobileEditorSectionHeading(eyebrow: "Example change", title: "What changed")

                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Agent proposal")
                            .font(MobileEditorFont.font(size: 14))
                            .foregroundColor(theme.editorColors.purple)
                        Text("Added a double jump and made the first section easier.")
                            .font(MobileEditorFont.font(size: 17))
                            .foregroundColor(theme.editorColors.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }

                Text("PROJECT CHANGES")
                    .font(MobileEditorFont.font(size: 11))
                    .foregroundColor(theme.editorColors.muted)

                change("Player", detail: "Added a second jump", symbol: "1")
                change("First scene", detail: "Moved a platform and a star", symbol: "2")
                change("AdaScript", detail: "Updated movement logic", symbol: "3")

                MobileEditorCard {
                    Text("This is an example comparison. Accepting changes only updates this prototype.")
                        .font(MobileEditorFont.font(size: 13))
                        .foregroundColor(theme.editorColors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(17)
                }

                if accepted {
                    Text("Example accepted")
                        .font(MobileEditorFont.font(size: 15))
                        .foregroundColor(theme.editorColors.blue)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("AdaEditor.Mobile.ReviewAccepted")
                } else {
                    MobileEditorPrimaryButton(title: "Accept example") {
                        accepted = true
                    }
                    .accessibilityIdentifier("AdaEditor.Mobile.AcceptReview")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background(theme.editorColors.background)
    }

    private func change(_ title: String, detail: String, symbol: String) -> some View {
        MobileEditorCard {
            HStack(spacing: 13) {
                Text(symbol)
                    .font(MobileEditorFont.font(size: 18))
                    .foregroundColor(theme.editorColors.blue)
                    .frame(width: 39, height: 39)
                    .background(RoundedRectangleShape(cornerRadius: 10).fill(theme.editorColors.blue.opacity(0.14)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(MobileEditorFont.font(size: 15))
                        .foregroundColor(theme.editorColors.text)
                    Text(detail)
                        .font(MobileEditorFont.font(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                }
                Spacer()
                Text("\u{E145}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 18))
                    .foregroundColor(theme.editorColors.blue)
            }
            .padding(14)
        }
    }
}
#endif
