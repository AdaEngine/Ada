//
//  TextLayoutCachingTests.swift
//  AdaEngine
//

import Math
import Testing
@testable import AdaText

struct TextLayoutCachingTests {

    @Test
    func firstInfiniteFitStillBuildsLayout() {
        let layoutManager = TextLayoutManager()

        layoutManager.fitToSize(.infinity)

        #expect(layoutManager.layoutRevision == 1)
    }

    @Test
    func fitToUnchangedSizeDoesNotInvalidateLayoutAgain() {
        let layoutManager = TextLayoutManager()
        let initialSize = Size(width: 320, height: 200)

        layoutManager.fitToSize(initialSize)
        let revisionAfterInitialLayout = layoutManager.layoutRevision

        layoutManager.fitToSize(initialSize)

        #expect(layoutManager.layoutRevision == revisionAfterInitialLayout)
    }

    @Test
    func fitToChangedSizeInvalidatesLayout() {
        let layoutManager = TextLayoutManager()

        layoutManager.fitToSize(Size(width: 320, height: 200))
        let revisionBeforeResize = layoutManager.layoutRevision

        layoutManager.fitToSize(Size(width: 321, height: 200))

        #expect(layoutManager.layoutRevision == revisionBeforeResize + 1)
    }
}
