#if os(macOS) || os(Windows) || os(Linux)
import AdaRender
import Foundation
import Testing

/// Compares the checked-in legacy Metal, SAGA Metal and SAGA Vulkan references. Needs no GPU.
///
/// The two backends rasterize and filter slightly differently, so agreement is judged with a wider tolerance than
/// a backend gets against its own references. A frame that differs more than that points at a real rendering
/// difference between the backends rather than rounding.
@Suite("Golden frame backend agreement")
struct GoldenBackendAgreementTests {
    /// Frames that are expected to differ between backends, with the reason.
    private static let expectedDifferences: [String: String] = [
        // The SAGA native encoder ignores triangle fill mode, so wireframe renders solid there.
        "pbr-spheres-wireframe": "SAGA native has no polygon fill mode",
        // The Metal bloom references date from 2026-10-16; the bloom, environment and composite code changed after them.
        // SAGA's bloom chain was checked level by level (each coarser level accumulates with the 0.7 scatter gain).
        // Re-record these two on Apple hardware to close the question.
        "emissive-bloom": "Metal reference predates the current bloom code",
        "emissive-bloom-exposure-minus1": "Metal reference predates the current bloom code",
    ]

    /// Vulkan-only references that wait for a Metal reference, which has to be recorded on Apple hardware. Record the
    /// frames in `GoldenFrames/saga-metal`, then remove the names from this set so the backends are compared again.
    private static let awaitingMetalReferences: Set<String> = ["atmosphere-noon", "atmosphere-low-sun", "atmosphere-night"]

    /// Largest per-channel step and fraction of pixels allowed to differ between backends.
    static let agreement = GoldenFrame.Tolerance(channelSteps: 12, differingFraction: 0.02)

    private static func names(in directory: String) throws -> Set<String> {
        let url = GoldenFrame.referenceURL(backend: directory, name: "x").deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return Set(try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
    }

    @Test func everySharedReferenceAgreesAcrossBackends() throws {
        let shared = try Self.names(in: "metal").intersection(Self.names(in: "saga")).subtracting(Self.expectedDifferences.keys)
        try Self.compareReferences(shared, "metal", "saga")
    }

    @Test func sagaMetalAndVulkanReferencesAgree() throws {
        let vulkan = try Self.names(in: "saga")
        let metal = try Self.names(in: "saga-metal")
        #expect(vulkan.subtracting(Self.awaitingMetalReferences) == metal, "SAGA Metal and Vulkan need references for the same scenes.")
        try Self.compareReferences(vulkan.intersection(metal), "saga", "saga-metal")
    }

    private static func compareReferences(_ shared: Set<String>, _ first: String, _ second: String) throws {
        try #require(!shared.isEmpty, "Both backends must have references to compare.")
        var report: [String] = []
        for name in shared.sorted() {
            let expected = try Image(contentsOf: GoldenFrame.referenceURL(backend: first, name: name))
            let actual = try Image(contentsOf: GoldenFrame.referenceURL(backend: second, name: name))
            let comparison = GoldenFrame.compare(actual, expected, tolerance: Self.agreement)
            report.append("\(name): \(comparison.differingPixels) px differ, largest step \(comparison.largestStep)")
            #expect(comparison.passes(Self.agreement), "\(name) differs between \(first) and \(second): \(comparison.differingPixels) pixels, largest step \(comparison.largestStep).")
        }
        print("BACKEND-AGREEMENT\n" + report.joined(separator: "\n"))
    }

    @Test func backendsHaveTheSameReferenceNames() throws {
        let metal = try Self.names(in: "metal")
        let saga = try Self.names(in: "saga")
        // SAGA native skips the temporal path and renders wireframe solid, but every other frame exists on both.
        #expect(metal.subtracting(saga).isSubset(of: ["pbr-spheres-wireframe"]) || metal.subtracting(saga).isEmpty, "Metal-only references: \(metal.subtracting(saga).sorted())")
        // The shaded-wireframe view has no Metal reference yet; record it on Apple hardware and drop this allowance.
        #expect(
            saga.subtracting(metal).isSubset(of: Set(["pbr-spheres-shadedWireframe"]).union(Self.awaitingMetalReferences)),
            "SAGA-only references: \(saga.subtracting(metal).sorted())"
        )
    }
}
#endif
