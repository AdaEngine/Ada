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
        Button {
            if let onOpen { onOpen() } else { refresh(true) }
        } label: {
            HStack(spacing: 4) {
                Text("\u{E65F}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    .foregroundColor(theme.editorColors.blue)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: compact ? 36 : 28)
            .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated))
        }
        .buttonStyle(DefaultButtonStyle())
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
            Text("AI credits")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(theme.editorColors.text)
            if let balance = model.balance {
                Text("\(EditorAICreditAmount.text(balance.available)) available")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.editorColors.blue)
                    .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Available")
                Text("\(EditorAICreditAmount.text(balance.spent)) used · \(EditorAICreditAmount.text(balance.reserved)) reserved · \(EditorAICreditAmount.text(balance.allowance)) per cycle")
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(2)
                if balance.cycleEnd > 0 {
                    Text("Cycle ends \(Date(timeIntervalSince1970: Double(balance.cycleEnd)).formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                }
            }
            Text(model.summary)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(3)
                .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Status")
            Button("Refresh credits", action: refresh)
                .font(.system(size: 14))
                .foregroundColor(theme.editorColors.blue)
                .frame(height: 36)
                .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Refresh")
            if model.phase == .ready {
                Text("Credit activity")
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
                    Text("No credit activity yet.").font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                }
                if let error = model.historyError {
                    Text(error).font(.system(size: 12)).foregroundColor(theme.editorColors.muted).lineLimit(2)
                }
                if model.hasMoreHistory || model.historyError != nil || model.loadingHistory {
                    Button(model.loadingHistory ? "Loading activity…" : "Load more activity", action: loadHistory)
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
        .onAppear { loadHistory() }
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
