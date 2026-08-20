import Observation
import SwiftUI
import UniformTypeIdentifiers

struct AppStoreReleaseView: View {
    @State private var model = AppStoreReleaseModel()
    @State private var isUploadConfirmationPresented = false
    @State private var isImportingConfiguration = false
    @State private var isExamplePresented = false
    @State private var shouldExportExampleAfterDismiss = false
    @State private var isExportingExample = false
    @State private var exampleDocument: AppStoreConfigurationDocument?
    @State private var isImportLocaleMapValid = true
    @State private var isScreenshotDirectoryMapValid = true

    var body: some View {
        HSplitView {
            configurationPane
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)

            workflowPane
                .frame(minWidth: 440)
        }
        .navigationTitle("iOS App 发版")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isImportingConfiguration = true
                } label: {
                    Label("导入配置", systemImage: "arrow.down.doc")
                }
                .help("导入本地 App Store Connect 配置")

                Button {
                    presentExample()
                } label: {
                    Label("示例配置", systemImage: "doc.text.magnifyingglass")
                }
                .help("下载示例配置文件")
            }
        }
        .confirmationDialog(
            "确认上传到 App Store Connect？",
            isPresented: $isUploadConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("上传 \(model.versionDisplayName)", role: .destructive) {
                model.runUpload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将上传 \(model.uploadLocaleSummary) 的商店物料，此操作会修改线上数据。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "未知错误")
        }
        .alert("首次使用发版流程", isPresented: $model.isFirstUse) {
            Button("查看示例配置") {
                presentExample()
            }
            Button("稍后设置", role: .cancel) {}
        } message: {
            Text("当前使用的是 DevKit 独立配置。你可以从右上角导入本地配置，也可以先下载示例配置修改后再导入。")
        }
        .fileImporter(
            isPresented: $isImportingConfiguration,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.importConfiguration(from: url)
            case .failure(let error):
                model.alertMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExportingExample,
            document: exampleDocument,
            contentType: .json,
            defaultFilename: "app_store_connect.example.json"
        ) { result in
            if case .failure(let error) = result {
                model.alertMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isExamplePresented, onDismiss: {
            guard shouldExportExampleAfterDismiss else { return }
            shouldExportExampleAfterDismiss = false
            isExportingExample = true
        }) {
            if let exampleDocument {
                AppStoreConfigurationExampleView(
                    content: exampleDocument.content,
                    onDownload: {
                        shouldExportExampleAfterDismiss = true
                        isExamplePresented = false
                    }
                )
            }
        }
        .onChange(of: model.configurationRevision) {
            isImportLocaleMapValid = true
            isScreenshotDirectoryMapValid = true
        }
    }

    private func presentExample() {
        do {
            exampleDocument = try AppStoreConfigurationDocument(
                data: AppStoreReleaseConfigurationFile.encodedData(
                    AppStoreReleaseConfigurationFile.exampleConfiguration()
                )
            )
            isExamplePresented = true
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var configurationPane: some View {
        if model.configuration != nil {
            ScrollView {
                AppStoreReleaseConfigurationForm(
                    configuration: Binding(
                        get: { model.configuration! },
                        set: { model.updateConfiguration($0) }
                    ),
                    configURL: model.configURL,
                    isImportLocaleMapValid: $isImportLocaleMapValid,
                    isScreenshotDirectoryMapValid: $isScreenshotDirectoryMapValid
                )
                .id(model.configurationRevision)
                .disabled(model.isRunning)
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: model.saveStatus.systemImage)
                    Text(model.saveStatus.message)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(model.saveStatus.isError ? .red : .secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        } else {
            ContentUnavailableView(
                "无法读取发版配置",
                systemImage: "doc.badge.gearshape",
                description: Text(model.alertMessage ?? model.configURL.path)
            )
        }
    }

    private var workflowPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("发版物料")
                        .font(.headline)
                }

                Spacer()

                Button {
                    model.runImport()
                } label: {
                    Label("导入物料", systemImage: "tray.and.arrow.down")
                }
                .disabled(!canRun)

                Button {
                    isUploadConfirmationPresented = true
                } label: {
                    Label("确认上传", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
            }
            .controlSize(.large)
            .padding(20)

            Divider()

            VSplitView {
                materialPane
                    .frame(minHeight: 240)

                executionPane
                    .frame(minHeight: 150, idealHeight: 220)
            }
        }
    }

    private var materialPane: some View {
        Group {
            if model.materials.isEmpty {
                ContentUnavailableView(
                    "暂无本地物料",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("导入后将在这里展示各语种 metadata.json")
                )
            } else {
                HSplitView {
                    List(model.materials, selection: $model.selectedMaterialID) { material in
                        Text(material.locale)
                            .tag(material.id)
                    }
                    .frame(minWidth: 110, idealWidth: 130, maxWidth: 180)

                    ScrollView([.horizontal, .vertical]) {
                        Text(model.selectedMaterial?.content ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                }
            }
        }
    }

    private var executionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: model.operationStatusSystemImage)
                        .foregroundStyle(.secondary)
                }
                Text(model.operationStatus)
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(model.output.isEmpty ? "等待执行" : model.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                    Color.clear
                        .frame(height: 1)
                        .id("output-end")
                }
                .onChange(of: model.output) {
                    proxy.scrollTo("output-end", anchor: .bottom)
                }
            }
        }
    }

    private var canRun: Bool {
        model.configuration != nil
            && !model.isRunning
            && isImportLocaleMapValid
            && isScreenshotDirectoryMapValid
    }
}

private struct AppStoreReleaseConfigurationForm: View {
    @Binding var configuration: AppStoreReleaseConfiguration
    let configURL: URL
    @Binding var isImportLocaleMapValid: Bool
    @Binding var isScreenshotDirectoryMapValid: Bool

    var body: some View {
        Form {
            Section("App Store Connect 认证") {
                TextField("Issuer ID", text: $configuration.auth.issuerID)
                TextField("Key ID", text: $configuration.auth.keyID)
                PathField(
                    title: "私钥路径",
                    path: $configuration.auth.privateKeyPath,
                    selection: .file
                )
            }

            Section("App") {
                TextField("App ID", text: $configuration.app.appID)
                TextField("Bundle ID", text: $configuration.app.bundleID)
                TextField("版本号", text: $configuration.app.versionString)
                TextField("默认名称", text: $configuration.app.defaultName)
            }

            Section("物料导入") {
                PathField(
                    title: "物料目录",
                    path: materialDirectory,
                    selection: .directory
                )
                TextField("飞书表格", text: $configuration.importSettings.feishuSheetURL)
                LocaleListField(
                    title: "跳过语种（可选）",
                    locales: disabledLocales,
                    help: "填写后，这些 locale 不会导入或上传；留空则处理全部语种。"
                )
                StringMapField(
                    title: "语种映射（可选）",
                    mapping: $configuration.importSettings.localeMap,
                    isValid: $isImportLocaleMapValid,
                    help: "仅在飞书语言名称无法被内置规则识别时填写，例如 英语=en-US。"
                )
            }

            Section("App Store 上传") {
                PathField(
                    title: "截图目录",
                    path: $configuration.upload.screenshotsRoot,
                    selection: .directory
                )
                Text(
                    hasValidScreenshotDirectory
                        ? "将从该目录读取截图。"
                        : "目录为空或无效时，将跳过全部截图操作，包括清空线上截图。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Group {
                    StringMapField(
                        title: "截图目录映射（可选）",
                        mapping: $configuration.upload.localeScreenshotDirectoryMap,
                        isValid: $isScreenshotDirectoryMapValid,
                        help: "仅在截图子目录名与 locale 不一致时填写。"
                    )
                    TextField(
                        "截图显示类型",
                        text: $configuration.upload.defaultScreenshotDisplayType
                    )
                    Toggle(
                        "上传前清空截图",
                        isOn: $configuration.upload.clearExistingScreenshots
                    )
                }
                .disabled(!hasValidScreenshotDirectory)
                Toggle(
                    "允许创建本地化",
                    isOn: $configuration.upload.allowCreateLocalizations
                )
                Toggle(
                    "单语种失败后继续",
                    isOn: $configuration.upload.continueOnLocaleError
                )
                TextField(
                    "轮询间隔（秒）",
                    value: $configuration.upload.pollIntervalSeconds,
                    format: .number
                )
                TextField(
                    "轮询超时（秒）",
                    value: $configuration.upload.pollTimeoutSeconds,
                    format: .number
                )
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    private var materialDirectory: Binding<String> {
        Binding(
            get: { configuration.importSettings.localizationsRoot },
            set: {
                configuration.importSettings.localizationsRoot = $0
                configuration.upload.localizationsRoot = $0
            }
        )
    }

    private var disabledLocales: Binding<[String]> {
        Binding(
            get: { configuration.importSettings.disabledLocales },
            set: {
                configuration.importSettings.disabledLocales = $0
                configuration.upload.disabledLocales = $0
            }
        )
    }

    private var hasValidScreenshotDirectory: Bool {
        AppStoreReleaseConfigurationFile.existingDirectory(
            configuration.upload.screenshotsRoot,
            relativeTo: configURL
        ) != nil
    }
}

private struct LocaleListField: View {
    let title: String
    @Binding var locales: [String]
    let help: String
    @State private var text: String

    init(title: String, locales: Binding<[String]>, help: String) {
        self.title = title
        _locales = locales
        self.help = help
        _text = State(initialValue: locales.wrappedValue.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(title, text: $text, prompt: Text("en-US, id"))
                .onChange(of: text) { _, newValue in
                    locales = newValue
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StringMapField: View {
    let title: String
    @Binding var mapping: [String: String]
    @Binding var isValid: Bool
    let help: String
    @State private var text: String

    init(
        title: String,
        mapping: Binding<[String: String]>,
        isValid: Binding<Bool>,
        help: String
    ) {
        self.title = title
        _mapping = mapping
        _isValid = isValid
        self.help = help
        _text = State(initialValue: Self.formatted(mapping.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 64)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isValid ? Color.secondary.opacity(0.25) : Color.red)
                }
                .onChange(of: text) { _, newValue in
                    if let parsed = Self.parse(newValue) {
                        isValid = true
                        mapping = parsed
                    } else {
                        isValid = false
                    }
                }
            Text(isValid ? help : "每行使用 名称=值 格式")
                .font(.caption)
                .foregroundStyle(isValid ? Color.secondary : Color.red)
        }
    }

    private static func formatted(_ mapping: [String: String]) -> String {
        mapping.keys.sorted().map { "\($0)=\(mapping[$0] ?? "")" }.joined(separator: "\n")
    }

    private static func parse(_ text: String) -> [String: String]? {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            result[key] = value
        }
        return result
    }
}

private struct PathField: View {
    enum Selection: Equatable {
        case file
        case directory

        var contentType: UTType {
            switch self {
            case .file: .data
            case .directory: .folder
            }
        }

        func accepts(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return false
            }
            switch self {
            case .file: return !isDirectory.boolValue
            case .directory: return isDirectory.boolValue
            }
        }
    }

    let title: String
    @Binding var path: String
    let selection: Selection
    @State private var isImporterPresented = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", text: $path)
                Button {
                    isImporterPresented = true
                } label: {
                    Image(systemName: selection == .directory ? "folder" : "doc")
                }
                .buttonStyle(.borderless)
                .help(selection == .directory ? "选择目录" : "选择文件")
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: selection.accepts) else { return false }
                path = url.path
                return true
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [selection.contentType],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first,
                  selection.accepts(url) else {
                return
            }
            path = url.path
        }
    }
}

private struct AppStoreConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    var content: String {
        String(decoding: data, as: UTF8.self)
    }

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct AppStoreConfigurationExampleView: View {
    @Environment(\.dismiss) private var dismiss

    let content: String
    let onDownload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("示例配置")
                        .font(.title2.bold())
                    Text("下载后可编辑，再通过右上角“导入配置”覆盖本地值。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                Button("下载示例") {
                    onDownload()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
        }
        .frame(minWidth: 720, minHeight: 600)
    }
}

@MainActor
@Observable
private final class AppStoreReleaseModel {
    enum SaveStatus {
        case saved
        case saving
        case failed(String)

        var message: String {
            switch self {
            case .saved:
                "配置已保存到本地文件"
            case .saving:
                "正在保存配置"
            case .failed(let message):
                "保存失败：\(message)"
            }
        }

        var systemImage: String {
            switch self {
            case .saved:
                "checkmark.circle"
            case .saving:
                "arrow.triangle.2.circlepath"
            case .failed:
                "exclamationmark.triangle"
            }
        }

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let storageDirectoryURL: URL
    let configURL: URL
    var configuration: AppStoreReleaseConfiguration?
    var materials: [AppStoreMaterial] = []
    var selectedMaterialID: String?
    var output = ""
    var isRunning = false
    var operationStatus = "尚未执行"
    var operationStatusSystemImage = "terminal"
    var saveStatus: SaveStatus = .saved
    var alertMessage: String?
    var isFirstUse = false
    var configurationRevision = UUID()

    init(storageDirectoryURL: URL? = nil) {
        let resolvedStorageDirectory = storageDirectoryURL
            ?? AppStoreReleaseConfigurationFile.storageDirectoryURL
        self.storageDirectoryURL = resolvedStorageDirectory
        configURL = AppStoreReleaseConfigurationFile.configURL(
            storageDirectory: resolvedStorageDirectory
        )
        do {
            let prepared = try AppStoreReleaseConfigurationFile.prepareConfiguration(
                storageDirectory: resolvedStorageDirectory
            )
            configuration = prepared.configuration
            isFirstUse = prepared.isFirstUse
            try reloadMaterials()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    var selectedMaterial: AppStoreMaterial? {
        materials.first { $0.id == selectedMaterialID }
    }

    var versionDisplayName: String {
        guard let version = configuration?.app.versionString, !version.isEmpty else {
            return "当前版本"
        }
        return "版本 \(version)"
    }

    var uploadLocaleSummary: String {
        guard let configuration else { return "当前配置语种" }
        let disabled = Set(configuration.upload.disabledLocales)
        let locales = Set(configuration.importSettings.localeMap.values)
            .subtracting(disabled)
            .sorted()
        return locales.isEmpty ? "当前配置语种" : locales.joined(separator: "、")
    }

    func updateConfiguration(_ newValue: AppStoreReleaseConfiguration) {
        configuration = AppStoreReleaseConfigurationFile.normalizedForApp(newValue)
        saveStatus = .saving
        saveConfiguration()
    }

    func importConfiguration(from sourceURL: URL) {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let imported = AppStoreReleaseConfigurationFile.normalizedImportedConfiguration(
                try AppStoreReleaseConfigurationFile.load(from: sourceURL)
            )
            try AppStoreReleaseConfigurationFile.save(imported, to: configURL)
            configuration = imported
            configurationRevision = UUID()
            isFirstUse = false
            saveStatus = .saved
            try reloadMaterials()
            operationStatus = "配置导入完成"
            operationStatusSystemImage = "checkmark.circle"
        } catch {
            alertMessage = "配置导入失败：\(error.localizedDescription)"
        }
    }

    func runImport() {
        run(
            scriptName: "import_feishu_store_localizations",
            title: "正在从飞书导入物料",
            successTitle: "物料导入完成",
            reloadsMaterials: true
        )
    }

    func runUpload() {
        let skipsScreenshots = configuration.map {
            AppStoreReleaseConfigurationFile.existingDirectory(
                $0.upload.screenshotsRoot,
                relativeTo: configURL
            ) == nil
        } ?? true
        run(
            scriptName: "upload_localizations",
            title: "正在上传到 App Store Connect",
            successTitle: "App Store Connect 上传完成",
            reloadsMaterials: false,
            additionalArguments: skipsScreenshots ? ["--skip-screenshots"] : []
        )
    }

    private func run(
        scriptName: String,
        title: String,
        successTitle: String,
        reloadsMaterials: Bool,
        additionalArguments: [String] = []
    ) {
        guard !isRunning, configuration != nil else { return }
        guard saveConfiguration() else { return }
        guard let scriptURL = AppStoreReleaseConfigurationFile.scriptURL(named: scriptName) else {
            alertMessage = "App 内缺少脚本：\(scriptName).py"
            return
        }

        isRunning = true
        output = ""
        operationStatus = title
        operationStatusSystemImage = "terminal"

        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await StreamingProcess.run(
                    executableURL: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: [
                        "-l",
                        "-c",
                        "exec python3 -u \"$@\"",
                        "devkit",
                        scriptURL.path,
                        "--config",
                        configURL.path,
                    ] + additionalArguments,
                    currentDirectoryURL: storageDirectoryURL
                ) { chunk in
                    Task { @MainActor [weak self] in
                        self?.output.append(chunk)
                    }
                }
                isRunning = false
                if status == 0 {
                    operationStatus = successTitle
                    operationStatusSystemImage = "checkmark.circle"
                    if reloadsMaterials {
                        try reloadMaterials()
                    }
                } else {
                    operationStatus = "执行失败（退出码 \(status)）"
                    operationStatusSystemImage = "xmark.circle"
                    alertMessage = "脚本执行失败，退出码 \(status)。请查看执行日志。"
                }
            } catch {
                isRunning = false
                operationStatus = "执行失败"
                operationStatusSystemImage = "xmark.circle"
                alertMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        guard let configuration else { return false }
        do {
            let normalized = AppStoreReleaseConfigurationFile.normalizedForApp(configuration)
            self.configuration = normalized
            try AppStoreReleaseConfigurationFile.save(normalized, to: configURL)
            saveStatus = .saved
            return true
        } catch {
            saveStatus = .failed(error.localizedDescription)
            alertMessage = error.localizedDescription
            return false
        }
    }

    private func reloadMaterials() throws {
        guard let configuration else { return }
        let rootURL = AppStoreReleaseConfigurationFile.resolvedDirectory(
            configuration.importSettings.localizationsRoot,
            relativeTo: configURL
        )
        materials = try AppStoreMaterialLoader.load(from: rootURL)
        if !materials.contains(where: { $0.id == selectedMaterialID }) {
            selectedMaterialID = materials.first?.id
        }
    }
}

#Preview {
    NavigationStack {
        AppStoreReleaseView()
    }
    .frame(width: 1_100, height: 760)
}
