import Foundation
import Testing
@testable import devkit

@MainActor
struct GitChangedImageScannerTests {
    @Test(arguments: [false, true])
    func excludedDirectoryAliasCannotAdmitDirectChildImages(gitOnly: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("assets/deep/image.png", in: directory)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("build"),
            withDestinationURL: directory.appendingPathComponent("assets", isDirectory: true)
        )
        let source = directory.appendingPathComponent("build/deep/image.png")
        let batch = try GitChangedImageScanner.scanSelection(
            [source], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(batch.scans[0].images.isEmpty)
    }

    @Test(arguments: [false, true], ["DerivedData", "Packages"])
    func nestedWorktreeInsideExcludedDirectoryCannotBypassDirectoryRules(gitOnly: Bool, excludedName: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("\(excludedName)/dependencies/repo", isDirectory: true)
        try initializeRepository(repository)
        try write("image.png", in: repository)
        for root in [repository, repository.appendingPathComponent("image.png")] {
            let batch = try GitChangedImageScanner.scanSelection(
                [root], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
            )
            #expect(batch.scans[0].images.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func filesystemRootAndNonRepositoryDiscoveryTerminateWithoutEnumeratingRoot(gitOnly: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("image.png")
        try write("image.png", in: directory)
        let filesystemRoot = URL(fileURLWithPath: "/", isDirectory: true)
        #expect(try !GitChangedImageScanner.canFilter([filesystemRoot]))
        let fixture = ImageScannedImage(url: source, byteCount: 11)
        // Supply an isolated fixture; this test must never enumerate the user's filesystem root.
        let result = try GitChangedImageScanner.scanSelection(
            [filesystemRoot], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"],
            scanImage: { _ in ImageScanResult(images: [fixture]) }
        )
        #expect(!result.gitFilterAvailable && !result.usesGitFilter)
        #expect(result.scans[0].images.map(\.url) == [source])
    }

    @Test(arguments: [false, true])
    func generatedDirectoriesAreAlwaysExcludedForGitAndOutsideInputs(gitOnly: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for isRepository in [false, true] {
            let root = directory.appendingPathComponent(isRepository ? "repo" : "outside", isDirectory: true)
            if isRepository { try initializeRepository(root) }
            let allowed = ["visible.png", "build.png", "tmp.png", "DerivedData.png"]
            let excluded = ["build/image.png", "nested/BUILD/image.png", "tmp/image.png",
                            "deep/TmP/image.png", "DerivedData/image.png", "nested/dErIvEdDaTa/deep/image.png", "Packages/Library/image.png", "nested/pAcKaGeS/Library/image.png"]
            for name in allowed + excluded { try write(name, in: root) }
            let rawImages = (allowed + excluded).map {
                ImageScannedImage(url: root.appendingPathComponent($0), byteCount: 11)
            }
            let result = try GitChangedImageScanner.scanSelection(
                [root], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"],
                scanImage: { _ in ImageScanResult(images: rawImages) }
            )
            #expect(Set(result.scans[0].images.map(\.url.lastPathComponent)) == Set(allowed))
            #expect(result.scans[0].images.count == allowed.count)
            #expect(result.gitFilterAvailable == isRepository)

            for path in excluded {
                let file = root.appendingPathComponent(path)
                for directRoot in [file, file.deletingLastPathComponent()] {
                    let direct = try GitChangedImageScanner.scanSelection(
                        [directRoot], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"],
                        scanImage: { _ in
                            Issue.record("Excluded generated directories must be rejected before raw scanning")
                            return ImageScanResult(images: [ImageScannedImage(url: file, byteCount: 11)])
                        }
                    )
                    #expect(direct.scans[0].images.isEmpty)
                }
            }
            if isRepository {
                let directGit = try GitChangedImageScanner.scan([root], supportedExtensions: ["png"])
                #expect(Set(directGit[0].images.map(\.url.lastPathComponent)) == Set(allowed))
            }
        }
    }

    @Test(arguments: [false, true])
    func ignoreRulesAlwaysExcludeImagesIncludingTrackedFilesAndDirectInputs(gitOnly: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try initializeRepository(directory)
        try write("tracked.png", in: directory)
        try write("clean.png", in: directory)
        try git(["add", "."], in: directory)
        try commit(in: directory)
        try write(".agent-figma-checkin/\n*.blocked.png\n!keep.blocked.png\ntracked.png\n", as: ".gitignore", in: directory)
        try write("*.png\n!keep.png\n", as: "nested/.gitignore", in: directory)
        try write("info-only.png\n", as: ".git/info/exclude", in: directory)
        try write("tracked.png", in: directory, content: "tracked-but-now-ignored")
        for name in [".agent-figma-checkin/screen.png", "ignored 中文\n.blocked.png", "keep.blocked.png",
                     "nested/skip.png", "nested/keep.png", "info-only.png", "visible.png"] {
            try write(name, in: directory)
        }
        let batch = try GitChangedImageScanner.scanSelection(
            [directory], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(batch.gitFilterAvailable && batch.usesGitFilter == gitOnly)
        var expected: Set<String> = ["keep.blocked.png", "nested/keep.png", "visible.png"]
        if !gitOnly { expected.insert("clean.png") }
        #expect(Set(batch.scans[0].images.map { String($0.url.resolvingSymlinksInPath().path.dropFirst(directory.resolvingSymlinksInPath().path.count + 1)) }) == expected)

        for path in [".agent-figma-checkin", ".agent-figma-checkin/screen.png", "tracked.png", "nested/skip.png"] {
            let direct = try GitChangedImageScanner.scanSelection(
                [directory.appendingPathComponent(path)], onlyGitChangedImages: gitOnly,
                supportedExtensions: ["png"], scanImage: Self.ordinaryScan
            )
            #expect(direct.scans[0].images.isEmpty)
        }
        let directGitScan = try GitChangedImageScanner.scan([directory], supportedExtensions: ["png"])
        #expect(!directGitScan[0].images.contains { $0.url.lastPathComponent == "tracked.png" })
    }

    @Test(arguments: [false, true])
    func parentSelectionFindsEachRepositoryAndWorktreeWhileKeepingOutsideImages(gitOnly: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first", isDirectory: true)
        let second = directory.appendingPathComponent("second", isDirectory: true)
        let worktree = directory.appendingPathComponent("worktree", isDirectory: true)
        for repository in [first, second] {
            try initializeRepository(repository)
            try write("hidden.png\n", as: ".gitignore", in: repository)
            try write("visible.png", in: repository)
            try write("hidden.png", in: repository)
        }
        try git(["add", "."], in: first)
        try commit(in: first)
        try git(["worktree", "add", "--detach", worktree.path], in: first)
        try write("hidden.png", in: worktree)
        try write("info-only.png\n", as: ".git/info/exclude", in: first)
        try write("info-only.png", in: first)
        try write("info-only.png", in: worktree)
        try write("outside.png", in: directory)

        let parent = try GitChangedImageScanner.scanSelection(
            [directory], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(!parent.gitFilterAvailable && !parent.usesGitFilter)
        #expect(Set(parent.scans[0].images.map { String($0.url.resolvingSymlinksInPath().path.dropFirst(directory.resolvingSymlinksInPath().path.count + 1)) }) == [
            "first/visible.png", "second/visible.png", "worktree/visible.png", "outside.png"
        ])
        let mixed = try GitChangedImageScanner.scanSelection(
            [first, second, worktree, directory.appendingPathComponent("outside.png")],
            onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(!mixed.gitFilterAvailable && !mixed.usesGitFilter)
        #expect(mixed.scans.flatMap(\.images).count == 4)
        #expect(mixed.scans.flatMap(\.images).allSatisfy { ["visible.png", "outside.png"].contains($0.url.lastPathComponent) })
    }

    @Test func failingIgnoreCheckDoesNotPassImagesThroughInNormalMode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try initializeRepository(directory)
        try write("image.png", in: directory)
        let invalidExcludesFile = directory.appendingPathComponent("exclude-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidExcludesFile, withIntermediateDirectories: true)
        try git(["config", "core.excludesFile", invalidExcludesFile.path], in: directory)
        #expect(try GitChangedImageScanner.canFilter([directory]))
        do {
            _ = try GitChangedImageScanner.scanSelection(
                [directory], onlyGitChangedImages: false, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
            )
            Issue.record("A failed check-ignore must not permit unchecked images")
        } catch {
            #expect(error.localizedDescription.contains("exclude"))
        }
    }

    @Test(arguments: [false, true])
    func unreadableSymlinkIgnoreRulesFailClosedEvenWhenGitExitsOne(gitOnly: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try initializeRepository(directory)
        try write("image.png", in: directory)
        try write("image.png\n", as: "ignore-rules", in: directory)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(".gitignore"),
            withDestinationURL: directory.appendingPathComponent("ignore-rules")
        )
        do {
            _ = try GitChangedImageScanner.scanSelection(
                [directory], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
            )
            Issue.record("Unreadable ignore rules must not allow unchecked images into the queue")
        } catch {
            #expect(error.localizedDescription.contains(".gitignore"))
        }
    }

    @Test(arguments: [false, true])
    func ignoredSymlinkSourcesCannotBypassRulesThroughOutsideTargets(gitOnly: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repo", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try initializeRepository(repository)
        try write("image.png", in: outside)
        try write("visible.png", in: repository)
        try write("ignored-link.png\nignored-link-dir/\n", as: ".gitignore", in: repository)
        let fileLink = repository.appendingPathComponent("ignored-link.png")
        let directoryLink = repository.appendingPathComponent("ignored-link-dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: outside.appendingPathComponent("image.png"))
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)

        for root in [fileLink, directoryLink, directoryLink.appendingPathComponent("image.png")] {
            let batch = try GitChangedImageScanner.scanSelection(
                [root], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
            )
            #expect(!batch.gitFilterAvailable && !batch.usesGitFilter)
            #expect(batch.scans[0].images.isEmpty)
        }
        let entireRepository = try GitChangedImageScanner.scanSelection(
            [repository], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(entireRepository.scans[0].images.map(\.url.lastPathComponent) == ["visible.png"])
        let ordinaryOutsideImage = try GitChangedImageScanner.scanSelection(
            [outside.appendingPathComponent("image.png")], onlyGitChangedImages: gitOnly,
            supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(ordinaryOutsideImage.scans[0].images.count == 1)
    }

    @Test(arguments: [false, true])
    func systemTemporaryDirectoryAliasAboveRepositoryRemainsUsable(gitOnly: Bool) throws {
        let repository = URL(fileURLWithPath: "/tmp/GitIgnoreAliasTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try initializeRepository(repository)
        try write("hidden.png\n", as: ".gitignore", in: repository)
        try write("hidden.png", in: repository)
        try write("visible.png", in: repository)
        let batch = try GitChangedImageScanner.scanSelection(
            [repository], onlyGitChangedImages: gitOnly, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(batch.gitFilterAvailable && batch.usesGitFilter == gitOnly)
        #expect(batch.scans[0].images.map(\.url.lastPathComponent) == ["visible.png"])
    }

    @Test func filterEligibilityRequiresEveryInputToBeInsideAWorktree() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repo", isDirectory: true)
        try initializeRepository(repository)
        try write("assets/image.png", in: repository)
        let image = repository.appendingPathComponent("assets/image.png")
        let assets = image.deletingLastPathComponent()
        #expect(try !GitChangedImageScanner.canFilter([]))
        #expect(try GitChangedImageScanner.canFilter([repository, assets, image]))
        #expect(try !GitChangedImageScanner.canFilter([repository, directory]))
        #expect(try !GitChangedImageScanner.canFilter([repository.appendingPathComponent("missing.png")]))
        #expect(try !GitChangedImageScanner.canFilter([repository.appendingPathComponent(".git", isDirectory: true)]))
        let link = repository.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        #expect(try !GitChangedImageScanner.canFilter([repository, link]))
        let bare = directory.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try git(["init", "--bare", "--quiet"], in: bare)
        #expect(try !GitChangedImageScanner.canFilter([bare]))
    }

    @Test func selectionUsesNormalImagesForMixedInputsAndRechecksRepositoryEligibility() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repo", isDirectory: true)
        try initializeRepository(repository)
        try write("clean.png", in: repository)
        try git(["add", "."], in: repository)
        try commit(in: repository)
        try write("changed.png", in: repository)
        try write("outside.png", in: directory)
        let outside = directory.appendingPathComponent("outside.png")

        let filtered = try GitChangedImageScanner.scanSelection(
            [repository], onlyGitChangedImages: true, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(filtered.gitFilterAvailable && filtered.usesGitFilter)
        #expect(filtered.scans[0].images.map(\.url.lastPathComponent) == ["changed.png"])
        let disabled = try GitChangedImageScanner.scanSelection(
            [repository], onlyGitChangedImages: false, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(disabled.gitFilterAvailable && !disabled.usesGitFilter)
        #expect(disabled.scans[0].images.map(\.url.lastPathComponent) == ["changed.png", "clean.png"])
        let mixed = try GitChangedImageScanner.scanSelection(
            [repository, outside], onlyGitChangedImages: true, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(!mixed.gitFilterAvailable && !mixed.usesGitFilter)
        #expect(mixed.scans[0].images.map(\.url.lastPathComponent) == ["changed.png", "clean.png"])
        #expect(mixed.scans[1].images.map(\.url) == [outside])

        try FileManager.default.removeItem(at: repository.appendingPathComponent(".git", isDirectory: true))
        let removedRepository = try GitChangedImageScanner.scanSelection(
            [repository], onlyGitChangedImages: true, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(!removedRepository.gitFilterAvailable && !removedRepository.usesGitFilter)
        #expect(removedRepository.scans[0].images.count == 2)
        let empty = try GitChangedImageScanner.scanSelection(
            [], onlyGitChangedImages: true, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
        )
        #expect(!empty.gitFilterAvailable && !empty.usesGitFilter && empty.scans.isEmpty)
    }

    @Test func validWorktreeWithFailingStatusDoesNotFallBackToAllImages() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try initializeRepository(directory)
        try write("image.png", in: directory)
        try write("invalid-index", as: ".git/index", in: directory)
        #expect(try GitChangedImageScanner.canFilter([directory]))
        do {
            _ = try GitChangedImageScanner.scanSelection(
                [directory], onlyGitChangedImages: true, supportedExtensions: ["png"], scanImage: Self.ordinaryScan
            )
            Issue.record("A Git status failure must not silently select every image")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test func statusIncludesStagedUnstagedUntrackedAndRenameDestinationsOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try initializeRepository(directory)
        for name in ["clean.png", "staged.png", "unstaged.jpg", "old.png", "deleted.png"] {
            try write(name, in: directory)
        }
        try write("*.ignored.png\n", as: ".gitignore", in: directory)
        try git(["add", "."], in: directory)
        try commit(in: directory)
        try write("staged.png", in: directory, content: "staged-change")
        try git(["add", "staged.png"], in: directory)
        try write("staged.png", in: directory, content: "worktree-change-after-stage")
        try write("unstaged.jpg", in: directory, content: "unstaged-change")
        try git(["mv", "old.png", "renamed 图片\n.png"], in: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("deleted.png"))
        let untrackedName = "新 图片\n资源.PNG"
        try write(untrackedName, in: directory)
        try write("nested/new.png", in: directory)
        try write("skip.ignored.png", in: directory)
        try write("notes.txt", in: directory)
        let results = try GitChangedImageScanner.scan([directory], supportedExtensions: ["png", "jpg"])
        let names = Set(try #require(results.first).images.map {
            String($0.url.resolvingSymlinksInPath().path.dropFirst(directory.resolvingSymlinksInPath().path.count + 1))
        })
        #expect(names == ["staged.png", "unstaged.jpg", "renamed 图片\n.png", untrackedName, "nested/new.png"])
        #expect(results[0].images.allSatisfy { $0.byteCount > 0 })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.png").path))
    }

    @Test func rootsRestrictSelectionAndPreserveAliasesAcrossMultipleRepositories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first repo\n中文", isDirectory: true)
        let second = directory.appendingPathComponent("second", isDirectory: true)
        try initializeRepository(first)
        try initializeRepository(second)
        try write("assets/inside.png", in: first)
        try write("outside.png", in: first)
        try write("single.png", in: second)
        try write("other.png", in: second)
        // /tmp is an alias of /private/tmp on macOS; preserve whichever path the importer supplied.
        let firstAlias = URL(fileURLWithPath: first.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        let roots = [firstAlias.appendingPathComponent("assets", isDirectory: true), second.appendingPathComponent("single.png")]
        let results = try GitChangedImageScanner.scan(roots, supportedExtensions: ["png"])
        #expect(results.count == roots.count)
        #expect(results[0].images.map(\.url) == [roots[0].appendingPathComponent("inside.png")])
        #expect(results[1].images.map(\.url) == [roots[1]])
    }

    @Test func deletionRecordsAreExcludedEvenWhenFilesRemainAndDoNotConsumeFollowingRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try initializeRepository(directory)
        try write("ignored.png", in: directory, content: "ignored-original")
        try write("recreated.png", in: directory, content: "recreated-original")
        try write("old.png", in: directory, content: "rename-original")
        try git(["add", "."], in: directory)
        try commit(in: directory)

        try git(["rm", "--cached", "ignored.png", "recreated.png"], in: directory)
        try write("ignored.png\n", as: ".gitignore", in: directory)
        let recreated = directory.appendingPathComponent("recreated.png")
        try FileManager.default.removeItem(at: recreated)
        try write("recreated.png", in: directory, content: "new-untracked-image")
        try git(["mv", "old.png", "renamed 图片\n.png"], in: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("renamed 图片\n.png"))
        try write("tail.png", in: directory)

        let status = String(decoding: try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: directory), as: UTF8.self)
        #expect(status.contains("D  ignored.png\0"))
        #expect(status.contains("D  recreated.png\0") && status.contains("?? recreated.png\0"))
        #expect(status.contains("RD renamed 图片\n.png\0old.png\0"))
        let results = try GitChangedImageScanner.scan([directory], supportedExtensions: ["png"])
        #expect(results[0].images.map(\.url.lastPathComponent) == ["recreated.png", "tail.png"])
        #expect(results[0].images.filter { $0.url.lastPathComponent == "recreated.png" }.count == 1)
        #expect(try Data(contentsOf: directory.appendingPathComponent("ignored.png")) == Data("ignored-original".utf8))
    }

    @Test func symlinkImagesCannotEscapeRepositoryAndNonRepositoriesFailClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repo", isDirectory: true)
        try initializeRepository(repository)
        try write("outside.png", in: directory)
        try write("ordinary.png", in: repository)
        let link = repository.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: directory.appendingPathComponent("outside.png")
        )
        let result = try GitChangedImageScanner.scan([repository], supportedExtensions: ["png"])
        #expect(result[0].images.map(\.url.lastPathComponent) == ["ordinary.png"])
        #expect(try GitChangedImageScanner.scan([link], supportedExtensions: ["png"])[0].images.isEmpty)
        let internalLink = repository.appendingPathComponent("internal-link.png")
        try FileManager.default.createSymbolicLink(
            at: internalLink, withDestinationURL: repository.appendingPathComponent("ordinary.png")
        )
        let mixed = try GitChangedImageScanner.scan([repository, internalLink], supportedExtensions: ["png"])
        #expect(mixed[0].images.map(\.url.lastPathComponent) == ["ordinary.png"])
        #expect(mixed[1].images.isEmpty)
        do {
            _ = try GitChangedImageScanner.scan([directory], supportedExtensions: ["png"])
            Issue.record("A non-repository selection must not fall back to an unrestricted image scan")
        } catch {
            #expect(error.localizedDescription.contains("Git"))
        }
    }

    @Test func unbornRepositoryAndLinkedWorktreeAreSupported() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repo", isDirectory: true)
        try initializeRepository(repository)
        try write("first.png", in: repository)
        #expect(try GitChangedImageScanner.scan([repository], supportedExtensions: ["png"])[0].images.count == 1)
        try git(["add", "."], in: repository)
        try commit(in: repository)
        let worktree = directory.appendingPathComponent("worktree", isDirectory: true)
        try git(["worktree", "add", "--detach", worktree.path], in: repository)
        try write("first.png", in: worktree, content: "worktree-only-change")
        let results = try GitChangedImageScanner.scan([repository, worktree], supportedExtensions: ["png"])
        #expect(try GitChangedImageScanner.canFilter([repository, worktree]))
        #expect(results[0].images.isEmpty)
        #expect(results[1].images.map(\.url) == [worktree.appendingPathComponent("first.png")])
    }

    nonisolated private static func ordinaryScan(_ root: URL) -> ImageScanResult {
        ImageTaskScanner.scan(root, supportedExtensions: ["png"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitImageScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func initializeRepository(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "--quiet"], in: directory)
        try git(["config", "user.name", "DevKit Tests"], in: directory)
        try git(["config", "user.email", "devkit-tests@example.invalid"], in: directory)
    }

    private func commit(in directory: URL) throws {
        try git(["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"], in: directory)
    }

    private func write(_ name: String, in directory: URL, content: String = "image-bytes") throws {
        try write(content, as: name, in: directory)
    }

    private func write(_ contents: String, as name: String, in directory: URL) throws {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "Git fixture command failed: \(arguments)")
        if process.terminationStatus != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
