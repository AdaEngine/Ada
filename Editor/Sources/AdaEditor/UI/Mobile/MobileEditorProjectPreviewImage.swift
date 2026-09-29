#if os(iOS)
import AdaEngine

struct MobileEditorProjectPreviewImage: View {
    let project: MobileEditorProject
    let height: Float
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .mask(RoundedRectangleShape(cornerRadius: 18))
            } else {
                MobileEditorProjectPlaceholderImage(height: height)
            }
        }
        .onAppear {
            guard let directory = try? MobileAdaScriptProjectService.projectURL(for: project.id) else {
                return
            }
            image = EditorProjectPreviewStore(projectURL: directory).load()
        }
    }
}
#endif
