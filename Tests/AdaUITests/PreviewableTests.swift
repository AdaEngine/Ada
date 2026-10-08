import Testing
@testable import AdaUI

@Previewable(title: "Preview Test")
public struct PreviewableTestView: View {
    public var body: some View {
        EmptyView()
    }
}

@Previewable(title: "Internal Preview")
struct InternalPreviewableTestView: View {
    var body: some View {
        EmptyView()
    }
}

@Previewable(title: "Private Preview")
private struct PrivatePreviewableTestView: View {
    var body: some View {
        EmptyView()
    }
}

@Suite("Previewable macro")
struct PreviewableTests {
    @Test("previewable macro exposes Ada preview metadata")
    @MainActor
    func exposesPreviewMetadata() {
        #expect(PreviewableTestView.adaPreviewTitle == "Preview Test")
        _ = PreviewableTestView.makeAdaPreview()
    }

    @Test("previewable macro supports non-public views")
    @MainActor
    func supportsNonPublicViews() {
        #expect(InternalPreviewableTestView.adaPreviewTitle == "Internal Preview")
        #expect(PrivatePreviewableTestView.adaPreviewTitle == "Private Preview")
        _ = InternalPreviewableTestView.makeAdaPreview()
        _ = PrivatePreviewableTestView.makeAdaPreview()
    }
}
