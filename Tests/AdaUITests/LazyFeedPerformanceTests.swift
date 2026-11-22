import AdaInput
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

@MainActor
struct LazyFeedPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAUI_FEED_BENCH"] == "1"))
    func scrollFeed() throws {
        try Application.prepareForTest()
        for columns in [1, 3] {
            for startRow in [10, 250] {
                try measure(columns: columns, startRow: startRow)
            }
        }
    }

    private func measure(columns: Int, startRow: Int) throws {
        let tester = ViewTester {
            ScrollView(.vertical) {
                LazyVStack(
                    Array(0..<(1_000 + columns - 1) / columns),
                    id: \.self,
                    spacing: 0,
                    estimatedRowHeight: 72,
                    rowHeight: { _ in 72 },
                    overscan: 2
                ) { row in
                    HStack(spacing: 6) {
                        ForEach(row * columns..<min(1_000, (row + 1) * columns), id: \.self) { card in
                            HStack(spacing: 8) {
                                Color.blue.frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("News item \(card)").lineLimit(1)
                                    Text("A short, deterministic story.").lineLimit(2)
                                }
                            }
                            .frame(width: Float(710 / columns), height: 72)
                            .accessibilityIdentifier("feed-card-\(card)")
                        }
                    }
                    .frame(height: 72)
                }
            }
            .frame(width: 740, height: 432)
        }.setSize(Size(width: 740, height: 432)).performLayout()
        let point = Point(360, 190)
        let scroll = try #require(tester.sendMouseEvent(at: point, button: .scrollWheel, phase: .began) as? ScrollViewNode)
        tester.sendMouseEvent(at: point, button: .scrollWheel, phase: .cancelled)
        scroll.scrollToViewNodeIfFoundIt(startRow, anchor: .top)
        tester.sendMouseEvent(at: point, button: .scrollWheel, phase: .began)
        try #require(scroll.contentOffset.y == Float(startRow * 72))
        let clock = ContinuousClock()
        for index in 0..<140 {
            let oldOffset = scroll.contentOffset.y
            let start = clock.now
            tester.sendMouseEvent(
                at: point,
                button: .scrollWheel,
                phase: .changed,
                scrollDelta: Point(0, -0.24),
                time: Float(index + 1) / 60
            )
            let afterScroll = clock.now
            let context = UIGraphicsContext()
            tester.containerView.draw(in: tester.containerView.bounds, with: context)
            context.commitDraw()
            let end = clock.now
            try #require(abs(scroll.contentOffset.y - oldOffset - 24) < 0.05)
            let firstVisibleCard = Int(scroll.contentOffset.y / 72) * columns
            try #require(tester.findNodeByAccessibilityIdentifier("feed-card-\(firstVisibleCard)") != nil)
            try #require(!context.getDrawCommands().isEmpty)
            if index >= 20 {
                let input = nanoseconds(start.duration(to: afterScroll))
                let draw = nanoseconds(afterScroll.duration(to: end))
                print("FEED_SAMPLE,\(columns),\(startRow),\(index),\(input),\(draw),\(input + draw)")
            }
        }
    }

    private func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }
}
