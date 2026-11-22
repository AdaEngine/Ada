@_spi(AdaEngine) import AdaEngine
import Foundation

@MainActor
struct EditorAICreditsBadge: View {
    var model: EditorAICreditsModel = EditorCloudAccount.shared.aiCredits
    var compact = false
    var refresh: (Bool) -> Void = { force in Task { await EditorCloudAccount.shared.refreshAICredits(force: force) } }
    var onOpen: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        let usesQuietToolbarStyle = compact && AdaEngineStyleLayoutSpec.usesCompactWorkspace
        Button {
            if let onOpen { onOpen() } else { refresh(true) }
        } label: {
            HStack(spacing: 4) {
                Text("\u{E65F}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    .foregroundColor(theme.editorColors.blue)
                Text(L10n.tr(label))
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, usesQuietToolbarStyle ? 4 : 8)
            .frame(height: usesQuietToolbarStyle ? 26 : compact ? 36 : 28)
            .background {
                if !usesQuietToolbarStyle {
                    RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated)
                }
            }
        }
        .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
        .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Counter")
        .onAppear { refresh(false) }
    }

    private var label: String {
        guard compact else {
            return model.counterText
        }
        if model.phase == .ready, let balance = model.balance {
            return EditorAICreditAmount.text(balance.available)
        }
        return model.phase == .loading ? "…" : "—"
    }
}

@MainActor
struct EditorAICreditsDetails: View {
    var model: EditorAICreditsModel = EditorCloudAccount.shared.aiCredits
    var refresh: () -> Void = {
        Task {
            await EditorCloudAccount.shared.refreshAICredits(force: true)
            await EditorCloudAccount.shared.loadAIUsage(restart: true)
        }
    }
    var loadHistory: () -> Void = { Task { await EditorCloudAccount.shared.loadAIUsage() } }
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Cloud Pro includes 500 AI credits per month, shared across your devices."))
                .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
            Text(L10n.text("AI credits"))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(theme.editorColors.text)
            if let balance = model.balance {
                Text(L10n.text("\(EditorAICreditAmount.text(balance.available)) available"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.editorColors.blue)
                    .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Available")
                let spent = EditorAICreditAmount.text(balance.spent)
                let reserved = EditorAICreditAmount.text(balance.reserved)
                let allowance = EditorAICreditAmount.text(balance.allowance)
                Text(L10n.text("\(spent) used · \(reserved) reserved · \(allowance) per cycle"))
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(2)
                if balance.cycleEnd > 0 {
                    Text(L10n.text("Cycle ends \(Date(timeIntervalSince1970: Double(balance.cycleEnd)).formatted(date: .abbreviated, time: .omitted))"))
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                }
            }
            Text(L10n.tr(model.summary))
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(3)
                .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Status")
            Button(L10n.text("Refresh credits"), action: refresh)
                .font(.system(size: 14))
                .foregroundColor(theme.editorColors.blue)
                .frame(height: 36)
                .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Refresh")
            if model.phase == .ready {
                Text(L10n.text("Credit activity"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                ForEach(model.history) { entry in
                    HStack(spacing: 8) {
                        Text(activityTitle(entry.kind))
                        Spacer(minLength: 0)
                        Text(EditorAICreditAmount.text(entry.microcredits))
                    }
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                    .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Activity.\(entry.cursor)")
                }
                if model.history.isEmpty && !model.loadingHistory && model.historyError == nil {
                    Text(L10n.text("No credit activity yet.")).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                }
                if let error = model.historyError {
                    Text(error).font(.system(size: 12)).foregroundColor(theme.editorColors.muted).lineLimit(2)
                }
                if model.hasMoreHistory || model.historyError != nil || model.loadingHistory {
                    Button(model.loadingHistory ? L10n.text("Loading activity…") : L10n.text("Load more activity"), action: loadHistory)
                        .font(.system(size: 14))
                        .foregroundColor(theme.editorColors.blue)
                        .frame(height: 36)
                        .disabled(model.loadingHistory)
                        .accessibilityIdentifier("AdaEditor.Cloud.AICredits.MoreActivity")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Details")
        .onAppear { refresh() }
    }

    private func activityTitle(_ kind: String) -> String {
        switch kind {
        case "entitlement": "Allowance adjustment"
        case "reserve": "Reserved"
        case "settle": "Used"
        case "release": "Released"
        default: "Credit adjustment"
        }
    }
}
