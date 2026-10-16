import AppKit
import SwiftUI

struct ResizableSheetConfigurator: NSViewRepresentable {
    let initialSize: CGSize
    let minimumSize: CGSize

    func makeNSView(context: Context) -> NSView {
        ResizableSheetHostView(initialSize: initialSize, minimumSize: minimumSize)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResizableSheetHostView: NSView {
    private let initialSize: CGSize
    private let minimumSize: CGSize
    private var hasConfiguredWindow = false

    init(initialSize: CGSize, minimumSize: CGSize) {
        self.initialSize = initialSize
        self.minimumSize = minimumSize
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard !hasConfiguredWindow, let window else { return }

        // Configure once so SwiftUI updates never reset a user-resized sheet.
        hasConfiguredWindow = true
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumSize
        window.setContentSize(initialSize)
    }
}
