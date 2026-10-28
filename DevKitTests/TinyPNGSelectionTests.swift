import Foundation
import Testing
@testable import devkit

@MainActor
struct TinyPNGSelectionTests {
    private func item(_ name: String, bytes: Int64 = 100 * 1024,
                      status: ImageCompressionTaskStatus = .waiting) -> TinyPNGImageItem {
        TinyPNGImageItem(id: URL(fileURLWithPath: "/tmp/\(name).png"), relativePath: "\(name).png",
                         byteCount: bytes, status: status)
    }

    @Test func manualSkipsUseSizeAndFilenameOrderAndCanReturn() async throws {
        let model = TinyPNGModel(preferencesDefaults: try isolatedDefaults())
        model.minimumCompressionSizeKB = 50
        model.imageItems = [item("automatic", bytes: 1, status: .skipped), item("first"), item("second")]
        await model.setCompressionEnabled(false, for: model.imageItems[2].id)
        await model.setCompressionEnabled(false, for: model.imageItems[1].id)
        #expect(model.displayGroups[1].tasks.map(\.title) == ["first.png", "second.png", "automatic.png"])
        #expect(model.displayGroups[1].tasks.allSatisfy { $0.compressionEnabled == false })

        await model.setCompressionEnabled(true, for: model.imageItems[2].id)
        #expect(model.displayGroups[0].tasks.map(\.title) == ["second.png"])
        #expect(model.displayGroups[1].tasks.map(\.title) == ["first.png", "automatic.png"])
        await model.setCompressionEnabled(false, for: model.imageItems[2].id)
        #expect(model.displayGroups[1].tasks.map(\.title) == ["first.png", "second.png", "automatic.png"])
    }

    @Test func manualChoicesOverrideThresholdButNeverUploadLimit() async throws {
        let model = TinyPNGModel(preferencesDefaults: try isolatedDefaults())
        model.imageItems = [item("manualOn", bytes: 1), item("manualOff"), item("automatic"),
                            item("oversized", bytes: TinyPNGInputScanner.maxUploadBytes + 1, status: .skipped)]
        await model.setCompressionEnabled(true, for: model.imageItems[0].id)
        await model.setCompressionEnabled(false, for: model.imageItems[1].id)
        model.minimumCompressionSizeKB = 200
        #expect(model.imageItems.map(\.status) == [.waiting, .skipped, .skipped, .skipped])
        await model.setCompressionEnabled(true, for: model.imageItems[3].id)
        #expect(!model.isCompressionEnabled(for: model.imageItems[3]))
        let oversized = try #require(model.displayGroups[1].tasks.first)
        #expect(oversized.id == model.imageItems[3].id)
        #expect(!oversized.compressionToggleAllowed)
        model.minimumCompressionSizeKB = 0
        #expect(model.imageItems.map(\.status) == [.waiting, .skipped, .waiting, .skipped])
    }

    @Test func completedResultsStayEnabledAfterThresholdChangesAndCannotRunAgain() throws {
        let model = TinyPNGModel(preferencesDefaults: try isolatedDefaults())
        model.selectedURLs = [URL(fileURLWithPath: "/tmp")]
        model.imageItems = [item("done", status: .success)]
        model.minimumCompressionSizeKB = 200
        #expect(model.displayGroups[0].tasks.first?.compressionEnabled == true)
        #expect(!model.canRun)
    }

    @Test func thresholdReclassifiesFailedAndCancelledImagesWithoutResults() throws {
        let model = TinyPNGModel(preferencesDefaults: try isolatedDefaults())
        model.imageItems = [item("failed", status: .failed("network")), item("cancelled", status: .cancelled)]
        model.minimumCompressionSizeKB = 200
        #expect(model.displayGroups[0].tasks.isEmpty)
        #expect(model.displayGroups[1].tasks.count == 2)
        model.minimumCompressionSizeKB = 0
        #expect(model.imageItems.allSatisfy { $0.status == .waiting })
    }

    @Test func replacementResetRestoresOriginalBytesAndPermissionsThenAllowsReenable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let original = Data("original-image".utf8)
        try original.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let snapshots = ImageCompressionOriginals()
        let snapshot = try await snapshots.capture(at: source)
        try Data("compressed".utf8).write(to: source)
        let model = TinyPNGModel(preferencesDefaults: try isolatedDefaults())
        model.selectedURLs = [source]
        model.imageItems = [TinyPNGImageItem(
            id: source, relativePath: "source.png", byteCount: Int64(original.count), status: .success,
            compressedByteCount: 10, compressionPercentage: 20, elapsedSeconds: 1,
            destinationPath: source.path, previewOriginalURL: snapshot
        )]
        // Reset must use the actual destination even if the global replacement option changed.
        model.replaceOriginals = false
        await model.resetResult(for: source)
        #expect(try Data(contentsOf: source) == original)
        let permissions = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int
        #expect(permissions == 0o640)
        #expect(model.imageItems[0].status == .skipped)
        #expect(model.imageItems[0].compressedByteCount == nil)
        #expect(model.displayGroups[1].tasks[0].compressionEnabled == false)
        #expect(!model.displayGroups[1].tasks[0].canPreview)
        #expect(model.compressionStats?.savedPercentage == 0)
        #expect(!model.canRun)
        await model.setCompressionEnabled(true, for: source)
        #expect(model.imageItems[0].status == .waiting)
        #expect(model.canRun)
        withExtendedLifetime(snapshots) {}
    }

    @Test func disablingCompletedOutputRestoresUncompressedCopyWithoutChangingSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let result = directory.appendingPathComponent("result.png")
        let original = Data("original-image".utf8)
        try original.write(to: source)
        try Data("compressed".utf8).write(to: result)
        let model = TinyPNGModel(preferencesDefaults: try isolatedDefaults())
        model.imageItems = [TinyPNGImageItem(id: source, relativePath: "source.png", byteCount: 14,
                                            status: .success, destinationPath: result.path)]
        await model.setCompressionEnabled(false, for: source)
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: result) == original)
        #expect(model.imageItems[0].status == .skipped)
        #expect(model.alertMessage == nil)
    }

    @Test func failedResetKeepsResultAndSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("missing.png")
        let result = directory.appendingPathComponent("result.png")
        let compressed = Data("compressed".utf8)
        try compressed.write(to: result)
        let model = TinyPNGModel(preferencesDefaults: try isolatedDefaults())
        model.imageItems = [TinyPNGImageItem(id: source, relativePath: "missing.png", byteCount: 14,
                                            status: .success, destinationPath: result.path)]
        let before = model.imageItems
        await model.resetResult(for: source)
        #expect(model.imageItems == before)
        #expect(try Data(contentsOf: result) == compressed)
        #expect(model.alertMessage != nil)
        #expect(!model.isRestoring)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["result.png"])
    }

    private func isolatedDefaults() throws -> UserDefaults {
        // An isolated suite prevents these cases from changing the user's saved threshold.
        let defaults = try #require(UserDefaults(suiteName: "TinyPNGSelectionTests-\(UUID().uuidString)"))
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        return defaults
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
