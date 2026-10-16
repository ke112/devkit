import Foundation
import Testing
@testable import devkit

struct ImageCompressionPreviewTests {
    @Test func replacementSnapshotRetainsSourceBytesAndName() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("comparison-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        let original = Data([1, 2, 3, 4])
        try original.write(to: source)

        let snapshots = ImageCompressionOriginals()
        let preserved = try await snapshots.capture(at: source)
        try Data([5, 6]).write(to: source)

        #expect(preserved != source)
        #expect(preserved.lastPathComponent == source.lastPathComponent)
        #expect(try Data(contentsOf: preserved) == original)
        withExtendedLifetime(snapshots) {}
    }

    @Test @MainActor func displayModelUsesPreservedOriginalAndActualDestination() {
        let source = URL(fileURLWithPath: "/tmp/source.png")
        let preserved = URL(fileURLWithPath: "/tmp/snapshot/source.png")
        let item = LubanImageItem(
            id: source,
            relativePath: "source.png",
            byteCount: 1_000,
            status: .success,
            destinationPath: "/tmp/output/source.jpg",
            previewOriginalURL: preserved
        )
        let display = ImageTaskDisplayModel(item: item, resultLabel: "压缩后", verb: "压缩")

        #expect(display.originalPreviewURL == preserved)
        #expect(display.destinationPath == "/tmp/output/source.jpg")
        #expect(display.canPreview)
    }

    @Test @MainActor func separateOutputUsesSourceAndRequiresDestination() {
        let source = URL(fileURLWithPath: "/tmp/source.png")
        var item = WebPImageItem(id: source, relativePath: "source.png", byteCount: 1_000, status: .success)
        var display = ImageTaskDisplayModel(item: item, resultLabel: "转换后", verb: "转换")
        #expect(display.originalPreviewURL == source)
        #expect(!display.canPreview)

        item.destinationPath = "/tmp/output/source.webp"
        display = ImageTaskDisplayModel(item: item, resultLabel: "转换后", verb: "转换")
        #expect(display.canPreview)
        #expect(display.resultLabel == "转换后")

        item.status = .skipped
        display = ImageTaskDisplayModel(item: item, resultLabel: "转换后", verb: "转换")
        #expect(!display.canPreview)
    }
}
