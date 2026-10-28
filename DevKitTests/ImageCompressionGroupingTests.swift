import Foundation
import Testing
@testable import devkit

@MainActor
struct ImageCompressionGroupingTests {
    enum Tool: CaseIterable {
        case tinyPNG, luban, webP
    }

    @Test(arguments: Tool.allCases)
    func groupsKeepOriginalSizeOrderAcrossSelectionChanges(tool: Tool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "ImageGrouping-\(UUID().uuidString)"))
        switch tool {
        case .tinyPNG:
            let model = TinyPNGModel(preferencesDefaults: defaults)
            try await checkGrouping(model, makeItem: {
                TinyPNGImageItem(id: $0, relativePath: $1, byteCount: $2, status: $3)
            }, setThreshold: { model.minimumCompressionSizeKB = $0 })
        case .luban:
            let model = LubanCompressionModel(preferencesDefaults: defaults)
            try await checkGrouping(model, makeItem: {
                LubanImageItem(id: $0, relativePath: $1, byteCount: $2, status: $3)
            }, setThreshold: { model.minimumCompressionSizeKB = $0 })
        case .webP:
            let model = WebPConversionModel(preferencesDefaults: defaults)
            try await checkGrouping(model, makeItem: {
                WebPImageItem(id: $0, relativePath: $1, byteCount: $2, status: $3)
            }, setThreshold: { model.minimumCompressionSizeKB = $0 })
        }
    }

    private func checkGrouping<M: ImageCompressionSelectionModel>(
        _ model: M,
        makeItem: (URL, String, Int64, ImageCompressionTaskStatus) -> M.ImageItem,
        setThreshold: (Int) -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let waiting = directory.appendingPathComponent("waiting.png")
        let small = directory.appendingPathComponent("small.png")
        let sameZ = directory.appendingPathComponent("z/same.png")
        let completed = directory.appendingPathComponent("completed.png")
        let image10 = directory.appendingPathComponent("image10.png")
        let large = directory.appendingPathComponent("large.png")
        let sameA = directory.appendingPathComponent("a/same.png")
        let image2 = directory.appendingPathComponent("image2.png")
        let result = directory.appendingPathComponent("result.png")
        let original = Data(repeating: 42, count: 6 * 1024)
        try original.write(to: completed)
        try Data([1]).write(to: result)

        setThreshold(1)
        var done = makeItem(completed, "completed.png", 6 * 1024, .success)
        done.destinationPath = result.path
        done.resultByteCount = 1
        var skippedLarge = makeItem(large, "large.png", 7 * 1024, .skipped)
        skippedLarge.compressionOverride = false
        skippedLarge.resultByteCount = 1
        var skippedSmall = makeItem(small, "small.png", 512, .skipped)
        skippedSmall.resultByteCount = 10 * 1024
        model.imageItems = [
            makeItem(waiting, "waiting.png", 1024, .waiting),
            skippedSmall,
            makeItem(sameZ, "same.png", 4 * 1024, .waiting),
            done,
            makeItem(image10, "image10.png", 3 * 1024, .failed("network")),
            skippedLarge,
            makeItem(sameA, "same.png", 4 * 1024, .cancelled),
            makeItem(image2, "image2.png", 3 * 1024, .waiting)
        ]
        let originalOrder = model.imageItems.map(\.id)

        // Completed output is tiny; grouping still uses its original source size.
        #expect(model.displayGroups[0].tasks.map(\.id) == [completed, sameA, sameZ, image2, image10, waiting])
        #expect(model.displayGroups[1].tasks.map(\.id) == [large, small])
        #expect(model.imageItems.map(\.id) == originalOrder)

        setThreshold(4)
        #expect(model.displayGroups[0].tasks.map(\.id) == [completed, sameA, sameZ])
        #expect(model.displayGroups[1].tasks.map(\.id) == [large, image2, image10, waiting, small])

        // Toggle in reverse path order so user action order cannot win the size/path ties.
        await model.setCompressionEnabled(false, for: sameZ)
        await model.setCompressionEnabled(false, for: sameA)
        await model.setCompressionEnabled(true, for: waiting)
        #expect(model.displayGroups[0].tasks.map(\.id) == [completed, waiting])
        #expect(model.displayGroups[1].tasks.map(\.id) == [large, sameA, sameZ, image2, image10, small])

        await model.resetResult(for: completed)
        #expect(model.alertMessage == nil)
        #expect(try Data(contentsOf: result) == original)
        #expect(model.displayGroups[0].tasks.map(\.id) == [waiting])
        #expect(model.displayGroups[1].tasks.map(\.id) == [large, completed, sameA, sameZ, image2, image10, small])

        setThreshold(0)
        #expect(model.displayGroups[0].tasks.map(\.id) == [image2, image10, waiting, small])
        #expect(model.displayGroups[1].tasks.map(\.id) == [large, completed, sameA, sameZ])
        #expect(model.imageItems.map(\.id) == originalOrder)
    }
}
