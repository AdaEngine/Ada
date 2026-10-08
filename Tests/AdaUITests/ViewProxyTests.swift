//
//  ViewProxyTests.swift
//  AdaEngine
//

import Math
import Testing
@testable import AdaPlatform
@testable import AdaUI

@MainActor
@Suite("ViewProxy")
struct ViewProxyTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test("@Environment viewProxy schedules display from initial body")
    func environmentViewProxySchedulesDisplayFromInitialBody() {
        let probe = ViewProxyProbe()
        let tester = ViewTester {
            ViewProxyCaptureView(probe: probe)
                .frame(width: 100, height: 40)
        }
        .setSize(Size(width: 160, height: 80))
        .performLayout()

        _ = tester.containerView.consumeNeedsDisplay()
        probe.proxy?.setNeedsDisplay()

        #expect(tester.containerView.needsDisplay)
    }

    @Test("viewProxy redraw invalidates display")
    func viewProxyRedrawInvalidatesDisplay() {
        let probe = ViewProxyProbe()
        let tester = ViewTester {
            ViewProxyCaptureView(probe: probe)
                .frame(width: 100, height: 40)
        }
        .setSize(Size(width: 160, height: 80))
        .performLayout()

        _ = tester.containerView.consumeNeedsDisplay()
        probe.proxy?.redraw()

        #expect(tester.containerView.needsDisplay)
    }
}

@MainActor
private final class ViewProxyProbe {
    var proxy: ViewProxy?
}

@MainActor
private struct ViewProxyCaptureView: View {
    @Environment(\.viewProxy) private var viewProxy

    let probe: ViewProxyProbe

    var body: some View {
        probe.proxy = viewProxy
        return Text("Proxy")
    }
}
