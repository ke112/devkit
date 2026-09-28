import AppKit
import Foundation
import Testing
@testable import devkit

struct AppBuildInfoTests {
    @Test func normalizedCommitHashTrimsSurroundingWhitespace() {
        #expect(AppBuildInfo.normalizedCommitHash("a1acbea\n") == "a1acbea")
        #expect(AppBuildInfo.normalizedCommitHash("  a1acbea  ") == "a1acbea")
    }

    @Test func normalizedCommitHashBlankValueBecomesNil() {
        #expect(AppBuildInfo.normalizedCommitHash("") == nil)
        #expect(AppBuildInfo.normalizedCommitHash("   \n") == nil)
    }

    @Test func testHostAppEmbedsCommitHashResource() {
        #expect(AppBuildInfo.commitShortHash(from: .main) != nil)
    }

    @Test func copyCommitShortHashWritesHashToPasteboard() {
        #expect(AppBuildInfo.copyCommitShortHashToPasteboard(from: .main))
        #expect(NSPasteboard.general.string(forType: .string) != nil)
    }
}
