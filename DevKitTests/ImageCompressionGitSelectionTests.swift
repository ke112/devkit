import Foundation
import Testing
@testable import devkit

@MainActor
private protocol GitSelectionTestModel: ImageCompressionSelectionModel {
    var onlyGitChangedImages: Bool { get set }
    var isGitFilterAvailable: Bool { get }
    var replaceOriginals: Bool { get set }
    var minimumCompressionSizeKB: Int { get set }
    var canRun: Bool { get }
    var outputDirectoryURL: URL? { get }
    func choose(_ urls: [URL])
    func refreshSelection()
    func clearSelection()
    func stop()
}

extension TinyPNGModel: GitSelectionTestModel {
    fileprivate func choose(_ urls: [URL]) { _ = select(urls: urls) }
    fileprivate func refreshSelection() { _ = select(urls: selectedURLs, refreshing: true) }
}

extension LubanCompressionModel: GitSelectionTestModel {
    fileprivate func choose(_ urls: [URL]) { _ = select(urls: urls) }
    fileprivate func refreshSelection() { _ = select(urls: selectedURLs, refreshing: true) }
}

extension WebPConversionModel: GitSelectionTestModel {
    fileprivate func choose(_ urls: [URL]) { _ = select(urls: urls) }
    fileprivate func refreshSelection() { _ = select(urls: selectedURLs, refreshing: true) }
}

@Suite(.serialized)
@MainActor
struct ImageCompressionGitSelectionTests {
    enum Tool: CaseIterable { case tinyPNG, luban, webP }
    enum Scenario: CaseIterable {
        case replacementLock, toggleExistingSelection, nonRepository, noMatchingImages, clearSelection
        case hiddenThresholdDrops, hiddenThresholdRises
        case cancelFilterChange
    }
    enum RootCombination: CaseIterable {
        case bothGit, bothGitFilterOff, gitThenNonGit, nonGitThenGit, bothNonGit, firstRepositoryDisappears

        var firstIsGit: Bool {
            self == .bothGit || self == .bothGitFilterOff || self == .gitThenNonGit || self == .firstRepositoryDisappears
        }
        var secondIsGit: Bool {
            self == .bothGit || self == .bothGitFilterOff || self == .nonGitThenGit || self == .firstRepositoryDisappears
        }
        var startsEnabled: Bool { firstIsGit && self != .bothGitFilterOff }
    }

    @Test(arguments: Tool.allCases, Scenario.allCases)
    func gitSelectionAcrossTools(tool: Tool, scenario: Scenario) async throws {
        let suite = "GitSelection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        switch tool {
        case .tinyPNG:
            try await check(scenario, model: TinyPNGModel(preferencesDefaults: defaults))
        case .luban:
            try await check(scenario, model: LubanCompressionModel(preferencesDefaults: defaults))
        case .webP:
            try await check(scenario, model: WebPConversionModel(preferencesDefaults: defaults))
        }
    }

    private func check<M: GitSelectionTestModel>(_ scenario: Scenario, model: M) async throws {
        #expect(!model.onlyGitChangedImages)
        #expect(!model.isGitFilterAvailable)
        #expect(!model.replaceOriginals)
        model.onlyGitChangedImages = true
        #expect(!model.onlyGitChangedImages)
        #expect(!model.replaceOriginals)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clean = directory.appendingPathComponent("clean.png")
        try Data("clean-image".utf8).write(to: clean)
        let changesHiddenThreshold = scenario == .hiddenThresholdDrops || scenario == .hiddenThresholdRises
        if changesHiddenThreshold {
            try Data(repeating: 7, count: 1024).write(to: clean)
        }
        if scenario == .nonRepository {
            model.choose([directory])
            try await waitForScan(model)
            #expect(model.imageItems.count == 1)
            #expect(!model.isGitFilterAvailable)
            model.onlyGitChangedImages = true
            try await waitForScan(model)
            #expect(!model.onlyGitChangedImages)
            #expect(model.imageItems.map(\.id.lastPathComponent) == ["clean.png"])
            return
        }

        try initializeRepository(directory)
        if scenario == .cancelFilterChange {
            let dirty = directory.appendingPathComponent("dirty.png")
            try Data("dirty-image".utf8).write(to: dirty)
            model.choose([directory])
            try await waitForScan(model)
            let originalRoots = model.selectedURLs
            #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == ["clean.png", "dirty.png"])

            // Cancelling a mode change keeps both the prior switch state and its published list.
            model.onlyGitChangedImages = true
            #expect(model.isScanning)
            model.stop()
            #expect(!model.onlyGitChangedImages)
            #expect(!model.replaceOriginals)
            #expect(!model.isScanning)
            #expect(model.selectedURLs == originalRoots)
            #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == ["clean.png", "dirty.png"])

            model.onlyGitChangedImages = true
            try await waitForScan(model)
            #expect(model.imageItems.map(\.id.lastPathComponent) == ["dirty.png"])
            model.onlyGitChangedImages = false
            #expect(model.isScanning)
            model.stop()
            #expect(model.onlyGitChangedImages)
            #expect(model.replaceOriginals)
            #expect(!model.isScanning)
            #expect(model.selectedURLs == originalRoots)
            #expect(model.imageItems.map(\.id.lastPathComponent) == ["dirty.png"])

            model.onlyGitChangedImages = false
            try await waitForScan(model)
            #expect(!model.onlyGitChangedImages)
            #expect(!model.replaceOriginals)
            #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == ["clean.png", "dirty.png"])
            return
        }
        if changesHiddenThreshold {
            let lowersThreshold = scenario == .hiddenThresholdDrops
            model.minimumCompressionSizeKB = lowersThreshold ? 2 : 0
            model.choose([directory])
            try await waitForScan(model)
            #expect(model.imageItems.first?.status == (lowersThreshold ? .skipped : .waiting))
            model.onlyGitChangedImages = true
            try await waitForScan(model)
            #expect(model.imageItems.isEmpty)
            #expect(model.isGitFilterAvailable)

            model.minimumCompressionSizeKB = lowersThreshold ? 0 : 2
            model.onlyGitChangedImages = false
            try await waitForScan(model)
            let restored = try #require(model.imageItems.first)
            #expect(restored.byteCount == 1024)
            #expect(restored.compressionOverride == nil)
            #expect(restored.status == (lowersThreshold ? .waiting : .skipped))
            #expect(model.isCompressionEnabled(for: restored) == lowersThreshold)
            #expect(model.canRun == lowersThreshold)
            return
        }
        if scenario == .replacementLock || scenario == .clearSelection {
            model.choose([directory])
            #expect(model.isScanning)
            #expect(!model.isGitFilterAvailable)
            model.onlyGitChangedImages = true
            #expect(!model.onlyGitChangedImages)
            try await waitForScan(model)
            #expect(model.isGitFilterAvailable)
            #expect(!model.onlyGitChangedImages)
            if scenario == .replacementLock {
                model.onlyGitChangedImages = true
                try await waitForScan(model)
                #expect(model.replaceOriginals)
                model.replaceOriginals = false
                #expect(model.replaceOriginals)
                model.onlyGitChangedImages = false
                try await waitForScan(model)
                #expect(!model.replaceOriginals)
                model.replaceOriginals = true
                model.onlyGitChangedImages = true
                try await waitForScan(model)
                model.onlyGitChangedImages = false
                try await waitForScan(model)
                #expect(model.replaceOriginals)
            } else {
                model.replaceOriginals = true
                model.onlyGitChangedImages = true
                try await waitForScan(model)
                model.clearSelection()
                #expect(model.selectedURLs.isEmpty)
                #expect(model.imageItems.isEmpty)
                #expect(!model.isGitFilterAvailable)
                #expect(!model.onlyGitChangedImages)
                #expect(model.replaceOriginals)
                model.onlyGitChangedImages = true
                #expect(!model.onlyGitChangedImages)
                model.choose([directory])
                try await waitForScan(model)
                #expect(model.isGitFilterAvailable)
                #expect(!model.onlyGitChangedImages)
            }
            return
        }
        if scenario == .noMatchingImages {
            model.choose([directory])
            try await waitForScan(model)
            #expect(model.isGitFilterAvailable)
            model.onlyGitChangedImages = true
            try await waitForScan(model)
            #expect(model.imageItems.isEmpty)
            // Retain the user's selected root so turning the filter off can restore its images.
            #expect(!model.selectedURLs.isEmpty)
            model.onlyGitChangedImages = false
            try await waitForScan(model)
            #expect(model.imageItems.map(\.id.lastPathComponent) == ["clean.png"])
            return
        }

        let staged = directory.appendingPathComponent("staged.png")
        let unstaged = directory.appendingPathComponent("unstaged.png")
        let completed = directory.appendingPathComponent("completed.png")
        let cleanResult = directory.appendingPathComponent("clean-result.png")
        let deleted = directory.appendingPathComponent("deleted.png")
        for file in [staged, unstaged, completed, cleanResult, deleted] {
            try Data("original-image".utf8).write(to: file)
        }
        try git(["add", "."], in: directory)
        try git(["commit", "-m", "Add image fixtures"], in: directory)
        try Data("staged-change".utf8).write(to: staged)
        try git(["add", "staged.png"], in: directory)
        try Data("unstaged-change".utf8).write(to: unstaged)
        try Data("completed-result".utf8).write(to: completed)
        try FileManager.default.removeItem(at: deleted)
        try Data("untracked-image".utf8).write(to: directory.appendingPathComponent("untracked.png"))
        try Data("ignored.png\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
        try Data("ignored-image".utf8).write(to: directory.appendingPathComponent("ignored.png"))
        model.choose([directory])
        try await waitForScan(model)
        #expect(model.imageItems.count == 7)
        let skippedID = try #require(model.imageItems.first { $0.id.lastPathComponent == "staged.png" }?.id)
        await model.setCompressionEnabled(false, for: skippedID)
        let cleanID = try #require(model.imageItems.first { $0.id.lastPathComponent == "clean.png" }?.id)
        await model.setCompressionEnabled(false, for: cleanID)
        let outputDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let output = outputDirectory.appendingPathComponent("compressed.png")
        try Data("completed-output".utf8).write(to: output)
        let cleanResultIndex = try #require(model.imageItems.firstIndex { $0.id.lastPathComponent == "clean-result.png" })
        model.imageItems[cleanResultIndex].status = .success
        model.imageItems[cleanResultIndex].destinationPath = output.path
        model.imageItems[cleanResultIndex].resultByteCount = 16
        model.imageItems[cleanResultIndex].resultReplacedOriginal = false
        let completedIndex = try #require(model.imageItems.firstIndex { $0.id.lastPathComponent == "completed.png" })
        model.imageItems[completedIndex].status = .success
        model.imageItems[completedIndex].destinationPath = completed.path
        model.imageItems[completedIndex].resultByteCount = 16
        model.imageItems[completedIndex].resultReplacedOriginal = true

        model.onlyGitChangedImages = true
        try await waitForScan(model)
        #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == [
            "staged.png", "unstaged.png", "untracked.png", "completed.png"
        ])
        let skipped = try #require(model.imageItems.first { $0.id.lastPathComponent == "staged.png" })
        #expect(skipped.compressionOverride == false)
        #expect(skipped.status == .skipped)
        let retainedResult = try #require(model.imageItems.first { $0.id.lastPathComponent == "completed.png" })
        #expect(retainedResult.status == .success)
        #expect(retainedResult.destinationPath == completed.path)
        #expect(retainedResult.resultReplacedOriginal)

        model.onlyGitChangedImages = false
        try await waitForScan(model)
        #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == [
            "clean.png", "staged.png", "unstaged.png", "untracked.png", "ignored.png", "completed.png", "clean-result.png"
        ])
        #expect(model.imageItems.first { $0.id.lastPathComponent == "staged.png" }?.compressionOverride == false)
        let restoredClean = try #require(model.imageItems.first { $0.id.lastPathComponent == "clean.png" })
        #expect(restoredClean.compressionOverride == false)
        #expect(restoredClean.status == .skipped)
        let restoredCleanResult = try #require(model.imageItems.first { $0.id.lastPathComponent == "clean-result.png" })
        #expect(restoredCleanResult.status == .success)
        #expect(restoredCleanResult.destinationPath == output.path)
        #expect(restoredCleanResult.resultByteCount == 16)
        #expect(!restoredCleanResult.resultReplacedOriginal)
        #expect(model.displayGroups.flatMap(\.tasks).first { $0.id == restoredCleanResult.id }?.canReset == true)
    }

    @Test(arguments: Tool.allCases, RootCombination.allCases)
    func appendingRootsRechecksTheEntireSelection(tool: Tool, combination: RootCombination) async throws {
        let suite = "GitAppendRoots-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        switch tool {
        case .tinyPNG:
            try await checkAppendingRoots(combination, model: TinyPNGModel(preferencesDefaults: defaults))
        case .luban:
            try await checkAppendingRoots(combination, model: LubanCompressionModel(preferencesDefaults: defaults))
        case .webP:
            try await checkAppendingRoots(combination, model: WebPConversionModel(preferencesDefaults: defaults))
        }
    }

    private func checkAppendingRoots<M: GitSelectionTestModel>(_ combination: RootCombination, model: M) async throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let firstImage = first.appendingPathComponent("a.png")
        let newlyChanged = first.appendingPathComponent("a-new.png")
        for name in ["a.png", "a-new.png", "a-clean.png"] {
            try Data("initial-a".utf8).write(to: first.appendingPathComponent(name))
        }
        for name in ["b.png", "b-clean.png"] {
            try Data("initial-b".utf8).write(to: second.appendingPathComponent(name))
        }
        if combination.firstIsGit { try initializeRepository(first) }
        if combination.secondIsGit { try initializeRepository(second) }
        try Data("changed-a".utf8).write(to: firstImage)
        try Data("changed-b".utf8).write(to: second.appendingPathComponent("b.png"))
        model.choose([first])
        try await waitForScan(model)
        #expect(model.isGitFilterAvailable == combination.firstIsGit)
        #expect(!model.onlyGitChangedImages)
        if combination.startsEnabled {
            model.onlyGitChangedImages = true
            try await waitForScan(model)
            #expect(model.imageItems.map(\.id.lastPathComponent) == ["a.png"])
        }

        // Before adding B, A's previously changed image becomes clean and a previously clean image changes.
        if combination.firstIsGit {
            try git(["add", "a.png"], in: first)
            try git(["commit", "--quiet", "-m", "Commit A before appending B"], in: first)
        }
        let updatedBytes = Data("new change discovered while adding B".utf8)
        try updatedBytes.write(to: newlyChanged)
        if combination == .firstRepositoryDisappears {
            try FileManager.default.removeItem(at: first.appendingPathComponent(".git"))
        }
        model.choose([second])
        try await waitForScan(model)
        let bothAreGit = combination.firstIsGit && combination.secondIsGit && combination != .firstRepositoryDisappears
        let remainsEnabled = combination.startsEnabled && bothAreGit
        #expect(model.isGitFilterAvailable == bothAreGit)
        #expect(model.onlyGitChangedImages == remainsEnabled)
        #expect(model.replaceOriginals == remainsEnabled)
        #expect(Set(model.selectedURLs.map(\.standardizedFileURL.path)) == [
            first.standardizedFileURL.path, second.standardizedFileURL.path
        ])
        let names = Set(model.imageItems.map(\.id.lastPathComponent))
        if remainsEnabled {
            #expect(names == ["a-new.png", "b.png"])
        } else {
            #expect(names == ["a.png", "a-new.png", "a-clean.png", "b.png", "b-clean.png"])
        }
        #expect(model.imageItems.first { $0.id.lastPathComponent == "a-new.png" }?.byteCount == Int64(updatedBytes.count))
        if !bothAreGit {
            model.onlyGitChangedImages = true
            #expect(!model.onlyGitChangedImages)
        }
    }

    @Test(arguments: Tool.allCases, [false, true])
    func refreshingMissingInputKeepsAllSelectedRoots(tool: Tool, selectFiles: Bool) async throws {
        let suite = "GitMissingRootRefresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        switch tool {
        case .tinyPNG:
            try await checkMissingInputRoot(selectFiles: selectFiles, model: TinyPNGModel(preferencesDefaults: defaults))
        case .luban:
            try await checkMissingInputRoot(selectFiles: selectFiles, model: LubanCompressionModel(preferencesDefaults: defaults))
        case .webP:
            try await checkMissingInputRoot(selectFiles: selectFiles, model: WebPConversionModel(preferencesDefaults: defaults))
        }
    }

    @Test(arguments: [false, true])
    func lubanPreflightDoesNotProcessSurvivingSubsetOfMissingInput(selectFiles: Bool) async throws {
        let suite = "GitMissingRootPreflight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LubanCompressionModel(preferencesDefaults: defaults)
        try await checkMissingInputRoot(selectFiles: selectFiles, model: model, start: { model.run() })
    }

    private func checkMissingInputRoot<M: GitSelectionTestModel>(
        selectFiles: Bool, model: M, start: (() -> Task<Void, Never>?)? = nil
    ) async throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let firstImage = first.appendingPathComponent("a.png")
        let secondImage = second.appendingPathComponent("b.png")
        try Data("initial-a".utf8).write(to: firstImage)
        try Data("initial-b".utf8).write(to: secondImage)
        try initializeRepository(first)
        try initializeRepository(second)
        try Data("changed-a".utf8).write(to: firstImage)
        let secondBytes = Data("changed-b-must-stay-untouched".utf8)
        try secondBytes.write(to: secondImage)
        model.minimumCompressionSizeKB = 0
        let roots = selectFiles ? [firstImage, secondImage] : [first, second]
        model.choose(roots)
        try await waitForScan(model)
        model.onlyGitChangedImages = true
        try await waitForScan(model)
        #expect(model.isGitFilterAvailable)
        #expect(model.onlyGitChangedImages)
        #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == ["a.png", "b.png"])
        let originalRoots = model.selectedURLs
        try FileManager.default.removeItem(at: selectFiles ? firstImage : first)

        if let start {
            let run = try #require(start())
            await run.value
        } else {
            model.refreshSelection()
            try await waitForScan(model)
        }
        #expect(model.selectedURLs == originalRoots)
        #expect(!model.isGitFilterAvailable)
        #expect(!model.onlyGitChangedImages)
        #expect(!model.replaceOriginals)
        #expect(!model.isRunning)
        #expect(model.outputDirectoryURL == nil)
        let surviving = try #require(model.imageItems.first { $0.id.lastPathComponent == "b.png" })
        #expect(surviving.status == .waiting)
        #expect(try Data(contentsOf: secondImage) == secondBytes)
    }

    @Test func lubanRechecksGitAfterSelectionBeforeReplacingAnyImage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("changed.png")
        try Data("initial-image".utf8).write(to: source)
        try initializeRepository(directory)
        let changed = Data("newly-committed-image".utf8)
        try changed.write(to: source)
        let suite = "GitPreflight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LubanCompressionModel(preferencesDefaults: defaults, outputBaseDirectory: directory)
        model.minimumCompressionSizeKB = 0
        model.select(urls: [directory])
        try await waitForScan(model)
        model.onlyGitChangedImages = true
        try await waitForScan(model)
        #expect(model.imageItems.count == 1)
        #expect(model.canRun)
        try git(["add", "."], in: directory)
        try git(["commit", "-m", "Commit selected image before compression"], in: directory)
        let run = try #require(model.run())
        await run.value
        #expect(model.imageItems.isEmpty)
        #expect(!model.isRunning)
        #expect(model.outputDirectoryURL == nil)
        #expect(try Data(contentsOf: source) == changed)
    }

    @Test func lubanDoesNotStartCompressionWhenItsRepositoryDisappears() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("changed.png")
        let clean = directory.appendingPathComponent("clean.png")
        try Data("initial-image".utf8).write(to: source)
        try Data("clean-image".utf8).write(to: clean)
        try initializeRepository(directory)
        let changed = Data("changed-image".utf8)
        try changed.write(to: source)
        let suite = "GitMissingPreflight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LubanCompressionModel(preferencesDefaults: defaults, outputBaseDirectory: directory)
        model.minimumCompressionSizeKB = 0
        model.select(urls: [directory])
        try await waitForScan(model)
        model.onlyGitChangedImages = true
        try await waitForScan(model)
        #expect(model.imageItems.map(\.id.lastPathComponent) == ["changed.png"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".git"))
        let run = try #require(model.run())
        await run.value
        #expect(!model.isGitFilterAvailable)
        #expect(!model.onlyGitChangedImages)
        #expect(!model.replaceOriginals)
        #expect(!model.isRunning)
        #expect(model.outputDirectoryURL == nil)
        #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == ["changed.png", "clean.png"])
        #expect(model.imageItems.allSatisfy { $0.status == .waiting })
        #expect(try Data(contentsOf: source) == changed)
        #expect(try Data(contentsOf: clean) == Data("clean-image".utf8))
    }

    @Test func tinyPNGRefreshesPendingFileSizesWithoutLosingManualChoices() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let enabled = directory.appendingPathComponent("enabled.png")
        let automatic = directory.appendingPathComponent("automatic.png")
        let excluded = directory.appendingPathComponent("excluded.png")
        try Data([1]).write(to: enabled)
        try Data(repeating: 1, count: 2048).write(to: automatic)
        try Data(repeating: 1, count: 2048).write(to: excluded)
        try initializeRepository(directory)
        let suite = "GitCurrentSizes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TinyPNGModel(preferencesDefaults: defaults)
        model.minimumCompressionSizeKB = 1
        model.select(urls: [directory])
        try await waitForScan(model)
        let enabledID = try #require(model.imageItems.first { $0.id.lastPathComponent == "enabled.png" }?.id)
        let excludedID = try #require(model.imageItems.first { $0.id.lastPathComponent == "excluded.png" }?.id)
        await model.setCompressionEnabled(true, for: enabledID)
        await model.setCompressionEnabled(false, for: excludedID)

        let oversizedBytes = Int(TinyPNGInputScanner.maxUploadBytes) + 1
        try Data(repeating: 2, count: oversizedBytes).write(to: enabled)
        try Data([2]).write(to: automatic)
        try Data(repeating: 2, count: 4096).write(to: excluded)
        model.onlyGitChangedImages = true
        try await waitForScan(model)
        let oversized = try #require(model.imageItems.first { $0.id.lastPathComponent == "enabled.png" })
        #expect(oversized.byteCount == Int64(oversizedBytes))
        #expect(oversized.compressionOverride == true)
        #expect(oversized.status == .skipped)
        #expect(!model.isCompressionEnabled(for: oversized))
        let belowThreshold = try #require(model.imageItems.first { $0.id.lastPathComponent == "automatic.png" })
        #expect(belowThreshold.byteCount == 1)
        #expect(belowThreshold.compressionOverride == nil)
        #expect(belowThreshold.status == .skipped)
        let manuallyExcluded = try #require(model.imageItems.first { $0.id.lastPathComponent == "excluded.png" })
        #expect(manuallyExcluded.byteCount == 4096)
        #expect(manuallyExcluded.compressionOverride == false)
        #expect(manuallyExcluded.status == .skipped)
        #expect(model.selectionSummary?.oversizedCount == 1)

        // A later rescan releases the upload limit while preserving the explicit below-threshold opt-in.
        try Data([3, 3]).write(to: enabled)
        try Data(repeating: 3, count: 4096).write(to: automatic)
        model.onlyGitChangedImages = false
        try await waitForScan(model)
        let enabledAgain = try #require(model.imageItems.first { $0.id.lastPathComponent == "enabled.png" })
        #expect(enabledAgain.byteCount == 2)
        #expect(enabledAgain.compressionOverride == true)
        #expect(enabledAgain.status == .waiting)
        #expect(model.isCompressionEnabled(for: enabledAgain))
        let automaticAgain = try #require(model.imageItems.first { $0.id.lastPathComponent == "automatic.png" })
        #expect(automaticAgain.byteCount == 4096)
        #expect(automaticAgain.status == .waiting)
        #expect(model.selectionSummary?.oversizedCount == 0)
    }

    @Test func stoppingLubanFilterRefreshPreservesSelectionAndRejectsConcurrentAppend() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        try Data("original-image".utf8).write(to: source)
        try initializeRepository(directory)
        try Data("changed-image".utf8).write(to: source)
        let suite = "GitRefreshCancellation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LubanCompressionModel(preferencesDefaults: defaults)
        model.select(urls: [directory])
        try await waitForScan(model)
        let sourceID = try #require(model.imageItems.first?.id)
        await model.setCompressionEnabled(false, for: sourceID)
        let originalRoots = model.selectedURLs
        let originalItems = model.imageItems
        let extra = directory.appendingPathComponent("extra.png")
        try Data("new-image".utf8).write(to: extra)

        // Stay on MainActor: the refresh completion cannot publish between these immediate calls.
        model.onlyGitChangedImages = true
        #expect(model.isScanning)
        #expect(model.select(urls: [extra]) == nil)
        #expect(model.selectedURLs == originalRoots)
        #expect(model.imageItems == originalItems)
        model.stop()
        #expect(!model.isScanning)
        #expect(model.selectedURLs == originalRoots)
        #expect(model.imageItems == originalItems)
        #expect(model.imageItems.first?.compressionOverride == false)

        // Cancelling the refresh must also release the append guard for the next ordinary selection.
        let append = try #require(model.select(urls: [extra]))
        await append.value
        #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == ["source.png", "extra.png"])
        #expect(model.imageItems.first { $0.id == sourceID }?.compressionOverride == false)
        #expect(model.selectedURLs.contains(extra.standardizedFileURL))
    }

    @Test(arguments: [false, true])
    func webPReplacementRetainsDeletedSourceAcrossAppendAndReset(selectDirectory: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let result = directory.appendingPathComponent("result.webp")
        try Data("committed-image".utf8).write(to: source)
        try initializeRepository(directory)
        let original = Data("original-png-bytes-before-conversion".utf8)
        try original.write(to: source)
        let suite = "GitWebPReplacement-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WebPConversionModel(preferencesDefaults: defaults)
        let originalRoot = selectDirectory ? directory : source
        #expect(model.select(urls: [originalRoot]))
        try await waitForScan(model)
        model.onlyGitChangedImages = true
        try await waitForScan(model)
        #expect(model.onlyGitChangedImages)
        let sourceID = try #require(model.imageItems.first?.id)

        // Model the successful replacement without launching the conversion script.
        let originals = ImageCompressionOriginals()
        defer { withExtendedLifetime(originals) {} }
        let snapshot = try await originals.capture(at: source)
        try Data("webp-result".utf8).write(to: result)
        try FileManager.default.removeItem(at: source)
        let sourceIndex = try #require(model.imageItems.firstIndex { $0.id == sourceID })
        model.imageItems[sourceIndex].status = .success
        model.imageItems[sourceIndex].destinationPath = result.path
        model.imageItems[sourceIndex].previewOriginalURL = snapshot
        model.imageItems[sourceIndex].resultReplacedOriginal = true
        model.imageItems[sourceIndex].convertedByteCount = 11

        let second = directory.appendingPathComponent("b.png")
        try Data("second-image".utf8).write(to: second)
        #expect(model.select(urls: [second]))
        try await waitForScan(model)
        #expect(model.isGitFilterAvailable)
        #expect(model.onlyGitChangedImages)
        #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == ["source.png", "b.png"])
        let completed = try #require(model.imageItems.first { $0.id == sourceID })
        #expect(completed.status == .success)
        #expect(completed.previewOriginalURL == snapshot)
        #expect(completed.destinationPath == result.path)
        #expect(completed.resultReplacedOriginal)
        let display = try #require(model.displayGroups.flatMap(\.tasks).first { $0.id == sourceID })
        #expect(display.canPreview)
        #expect(display.canReset)
        #expect(display.originalPreviewURL == snapshot)

        await model.resetResult(for: sourceID)
        #expect(model.alertMessage == nil)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: result.path))
        let third = directory.appendingPathComponent("c.png")
        try Data("third-image".utf8).write(to: third)
        #expect(model.select(urls: [third]))
        try await waitForScan(model)
        #expect(model.isGitFilterAvailable)
        #expect(model.onlyGitChangedImages)
        #expect(Set(model.imageItems.map(\.id.lastPathComponent)) == ["source.png", "b.png", "c.png"])
        let restored = try #require(model.imageItems.first { $0.id == sourceID })
        #expect(restored.status == .skipped)
        #expect(restored.compressionOverride == false)
        #expect(!restored.resultReplacedOriginal)
        #expect(model.inputURLsForPendingItems().contains {
            $0.resolvingSymlinksInPath() == originalRoot.resolvingSymlinksInPath()
        })
    }

    private func waitForScan<M: ImageCompressionSelectionModel>(_ model: M) async throws {
        // Other image-processing suites can occupy MainActor while this scan's completion is queued.
        let deadline = ContinuousClock.now + .seconds(180)
        while model.isScanning && ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.isScanning, "Image scan did not finish within 180 seconds, including MainActor scheduling")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevKitGitSelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func initializeRepository(_ directory: URL) throws {
        try git(["init", "--quiet"], in: directory)
        try git(["config", "user.name", "DevKit Tests"], in: directory)
        try git(["config", "user.email", "devkit-tests@example.invalid"], in: directory)
        try git(["config", "commit.gpgsign", "false"], in: directory)
        try git(["add", "."], in: directory)
        try git(["commit", "--quiet", "-m", "Initial image fixtures"], in: directory)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Git fixture command failed: \(arguments)")
    }
}
