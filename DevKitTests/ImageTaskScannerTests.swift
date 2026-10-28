import Foundation
import Testing
@testable import devkit

@MainActor
struct ImageTaskScannerTests {
    @Test func parallelModuleSeedsProduceEveryImageExactlyOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var names = ["root.png"]
        for module in 0..<13 {
            names.append("Modules/Module\(module)/assets/image2.png")
            names.append("Modules/Module\(module)/assets/image10.PNG")
            try write("Modules/Module\(module)/Sources/file.swift", in: directory)
        }
        for name in names { try write(name, in: directory) }
        let result = ImageTaskScanner.scan(directory, supportedExtensions: ["png"])
        let paths = result.images.map { String($0.url.path.dropFirst(directory.path.count + 1)) }
        #expect(Set(paths) == Set(names))
        #expect(paths.count == Set(paths).count)
        #expect(result.images.allSatisfy { $0.byteCount == 11 })
        for pair in zip(result.images, result.images.dropFirst()) {
            #expect(pair.0.url.path.localizedStandardCompare(pair.1.url.path) == .orderedAscending)
        }
    }

    @Test func nativeTraversalPreservesImageNamesSizesExtensionsAndNaturalOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageNames = ["image10.PNG", "image2.png", "image1.jpg", ".hidden.png", "nested/中文 图片\n.png", "build.png"]
        var expectedSizes: [String: Int64] = [:]
        for (index, name) in imageNames.enumerated() {
            try write(name, bytes: index + 1, in: directory)
            expectedSizes[name] = Int64(index + 1)
        }
        for name in [".png", "image.png.swift", "notes.txt", "nested/other.jpeg"] {
            try write(name, in: directory)
        }
        // A directory whose name has an image extension must still be traversed.
        try write("folder.png/inside.jpg", bytes: 42, in: directory)
        expectedSizes["folder.png/inside.jpg"] = 42
        let result = ImageTaskScanner.scan(directory, supportedExtensions: ["png", "jpg"])
        let relativeNames = result.images.map { String($0.url.path.dropFirst(directory.path.count + 1)) }
        #expect(Set(relativeNames) == Set(expectedSizes.keys))
        for image in result.images {
            let name = String(image.url.path.dropFirst(directory.path.count + 1))
            #expect(image.byteCount == expectedSizes[name])
        }
        let one = try #require(relativeNames.firstIndex(of: "image1.jpg"))
        let two = try #require(relativeNames.firstIndex(of: "image2.png"))
        let ten = try #require(relativeNames.firstIndex(of: "image10.PNG"))
        #expect(one < two && two < ten)
    }

    @Test func generatedDirectoriesAndSymbolicLinksAreNeverTraversedOrReturned() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try write("visible.png", in: root)
        try write("outside.png", in: outside)
        for name in ["build/ignored.png", "nested/TmP/ignored.png", "nested/DerivedData/deep/ignored.png", "Packages/Library/ignored.png", "nested/pAcKaGeS/Library/image.png"] {
            try write(name, in: root)
        }
        let fileLink = root.appendingPathComponent("alias.png")
        let directoryLink = root.appendingPathComponent("directory-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: outside.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
        let result = ImageTaskScanner.scan(root, supportedExtensions: ["png"])
        #expect(result.images.map(\.url.lastPathComponent) == ["visible.png"])
        #expect(ImageTaskScanner.scan(fileLink, supportedExtensions: ["png"]).images.isEmpty)
        #expect(ImageTaskScanner.scan(directoryLink, supportedExtensions: ["png"]).images.isEmpty)
        #expect(ImageTaskScanner.scan(root.appendingPathComponent("build/ignored.png"), supportedExtensions: ["png"]).images.isEmpty)
        #expect(ImageTaskScanner.scan(root.appendingPathComponent("nested/DerivedData/deep", isDirectory: true), supportedExtensions: ["png"]).images.isEmpty)
    }

    @Test func excludedPackageResultsCannotReappearFromHistory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Packages/Library/source.png")
        let result = directory.appendingPathComponent("Packages/Library/source.webp")
        try write("Packages/Library/source.webp", in: directory)
        let model = WebPConversionModel()
        let previous = WebPImageItem(
            id: source, relativePath: "Packages/Library/source.png", byteCount: 11,
            status: .success, destinationPath: result.path, resultReplacedOriginal: true
        )
        #expect(model.retainingSelectionState(in: [], from: [previous]).isEmpty)
        #expect(try Data(contentsOf: result) == Data(repeating: 42, count: 11))
    }

    @Test func temporaryDirectoryAliasesAndDirectImageSizesRemainIntact() throws {
        let directory = URL(fileURLWithPath: "/tmp/ImageTaskScannerAliases-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("image.png", bytes: 37, in: directory)
        let source = directory.appendingPathComponent("image.png")
        let recursive = ImageTaskScanner.scan(directory, supportedExtensions: ["png"])
        #expect(recursive.images.map(\.url.path) == [source.path])
        #expect(recursive.images.first?.byteCount == 37)
        let direct = ImageTaskScanner.scan(source, supportedExtensions: ["png"])
        #expect(direct.images.map(\.url) == [source])
        #expect(direct.images.first?.byteCount == 37)
    }

    @Test func cancelledDirectoryScanReturnsWithoutEnteringChildren() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("nested/image.png", in: directory)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ImageTaskScanner.scan(directory, supportedExtensions: ["png"])
        }
        #expect(await worker.value.images.isEmpty)
    }

    @Test func cancellationDuringParallelTraversalStopsBeforePublishingModuleImages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("root.png", in: directory)
        for module in 0..<13 {
            for child in 0..<4 { try write("Modules/Module\(module)/assets\(child)/image.png", in: directory) }
        }
        let worker = Task.detached {
            withUnsafeCurrentTask { task in
                // The borrowed handle and callback cannot outlive this synchronous scan and its GCD join.
                let cancellation = RunningScanCancellation(task)
                let result = ImageTaskScanner.scan(directory, supportedExtensions: ["png"], onDirectoryScan: {
                    cancellation.directoryDidStart($0)
                })
                return (result, cancellation.startedDirectoryCount)
            }
        }
        let (result, started) = await worker.value
        #expect(started > 0 && started <= 4)
        #expect(result.images.map(\.url.lastPathComponent) == ["root.png"])
    }

    private final class RunningScanCancellation: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private let task: UnsafeCurrentTask?
        nonisolated(unsafe) private var started = 0

        nonisolated init(_ task: UnsafeCurrentTask?) { self.task = task }

        nonisolated func directoryDidStart(_ path: String) {
            lock.withLock {
                started += 1
                task?.cancel()
            }
        }

        nonisolated var startedDirectoryCount: Int { lock.withLock { started } }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageTaskScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ name: String, bytes: Int = 11, in directory: URL) throws {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: file)
    }
}
