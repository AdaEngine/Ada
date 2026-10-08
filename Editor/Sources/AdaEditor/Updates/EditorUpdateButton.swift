import AdaEngine

struct EditorUpdateButton: View {
    private let updater = EditorUpdateCenter.shared

    var body: some View {
        if EditorDistribution.current == .standalone, updater.availableVersion != nil {
            Button(action: updater.checkForUpdates) {
                Text("Update")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
            }
            .buttonStyle(DefaultButtonStyle())
            .background(RoundedRectangleShape(cornerRadius: 7).fill(Color(red: 0.32, green: 0.38, blue: 0.86)))
            .accessibilityIdentifier("AdaEditor.Update")
        }
    }
}
