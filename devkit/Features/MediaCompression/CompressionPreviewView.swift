import AppKit
import SwiftUI

struct MediaCompressionPreview: View {
    let item: MediaImageTask
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("压缩前后对比 — \(item.sourceURL.lastPathComponent)")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            HStack(spacing: 0) {
                previewColumn(title: "原始图片", url: item.sourceURL, bytes: item.originalBytes, size: item.originalSize)
                Divider()
                previewColumn(
                    title: item.usedFormat.map { "压缩后（\($0)）" } ?? "压缩后",
                    url: item.destinationURL,
                    bytes: item.compressedBytes,
                    size: item.compressedSize
                )
            }
            Divider()
            HStack(spacing: 24) {
                if let original = item.originalBytes, let compressed = item.compressedBytes, original > 0 {
                    Label("压缩后为原图的 \(String(format: "%.1f%%", Double(compressed) / Double(original) * 100))", systemImage: "chart.bar.fill")
                    Label("节省 \(mediaFormatBytes(original - compressed))", systemImage: "arrow.down.circle")
                }
                Spacer()
            }
            .font(.callout)
            .padding()
        }
        .frame(minWidth: 800, minHeight: 550)
    }

    private func previewColumn(title: String, url: URL?, bytes: Int64?, size: CGSize?) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 350)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(height: 220)
                    .overlay { Text("无法加载").foregroundStyle(.secondary) }
            }
            HStack(spacing: 16) {
                Label(mediaFormatBytes(bytes), systemImage: "doc")
                Label(mediaFormatDimensions(size), systemImage: "aspectratio")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
