import Foundation

struct AppStoreReleaseConfiguration: Codable, Equatable {
    var auth: Auth
    var app: App
    var importSettings: ImportSettings
    var upload: UploadSettings

    enum CodingKeys: String, CodingKey {
        case auth
        case app
        case importSettings = "import"
        case upload
    }

    struct Auth: Codable, Equatable {
        var issuerID: String
        var keyID: String
        var privateKeyPath: String

        enum CodingKeys: String, CodingKey {
            case issuerID = "issuer_id"
            case keyID = "key_id"
            case privateKeyPath = "private_key_path"
        }
    }

    struct App: Codable, Equatable {
        var appID: String
        var bundleID: String
        var platform: String
        var versionString: String
        var defaultName: String

        enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case bundleID = "bundle_id"
            case platform
            case versionString = "version_string"
            case defaultName = "default_name"
        }
    }

    struct ImportSettings: Codable, Equatable {
        var localizationsRoot: String
        var feishuSheetURL: String
        var larkIdentity: String
        var disabledLocales: [String]
        var localeMap: [String: String]

        enum CodingKeys: String, CodingKey {
            case localizationsRoot = "localizations_root"
            case feishuSheetURL = "feishu_sheet_url"
            case larkIdentity = "lark_identity"
            case disabledLocales = "disabled_locales"
            case localeMap = "locale_map"
        }
    }

    struct UploadSettings: Codable, Equatable {
        var localizationsRoot: String
        var screenshotsRoot: String
        var localeScreenshotDirectoryMap: [String: String]
        var disabledLocales: [String]
        var defaultScreenshotDisplayType: String
        var allowCreateLocalizations: Bool
        var clearExistingScreenshots: Bool
        var continueOnLocaleError: Bool
        var pollIntervalSeconds: Int
        var pollTimeoutSeconds: Int

        enum CodingKeys: String, CodingKey {
            case localizationsRoot = "localizations_root"
            case screenshotsRoot = "screenshots_root"
            case localeScreenshotDirectoryMap = "locale_screenshot_dir_map"
            case disabledLocales = "disabled_locales"
            case defaultScreenshotDisplayType = "default_screenshot_display_type"
            case allowCreateLocalizations = "allow_create_localizations"
            case clearExistingScreenshots = "clear_existing_screenshots"
            case continueOnLocaleError = "continue_on_locale_error"
            case pollIntervalSeconds = "poll_interval_seconds"
            case pollTimeoutSeconds = "poll_timeout_seconds"
        }
    }

    static let empty = AppStoreReleaseConfiguration(
        auth: Auth(issuerID: "", keyID: "", privateKeyPath: ""),
        app: App(
            appID: "",
            bundleID: "",
            platform: "IOS",
            versionString: "",
            defaultName: ""
        ),
        importSettings: ImportSettings(
            localizationsRoot: "localizations",
            feishuSheetURL: "",
            larkIdentity: "auto",
            disabledLocales: [],
            localeMap: [:]
        ),
        upload: UploadSettings(
            localizationsRoot: "localizations",
            screenshotsRoot: "",
            localeScreenshotDirectoryMap: [:],
            disabledLocales: [],
            defaultScreenshotDisplayType: "APP_IPHONE_67",
            allowCreateLocalizations: true,
            clearExistingScreenshots: true,
            continueOnLocaleError: false,
            pollIntervalSeconds: 5,
            pollTimeoutSeconds: 300
        )
    )
}

enum AppStoreReleaseConfigurationFile {
    static var storageDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DevKit/AppStoreRelease", directoryHint: .isDirectory)
    }

    static func configURL(storageDirectory: URL = storageDirectoryURL) -> URL {
        storageDirectory.appending(path: "app_store_connect.json")
    }

    static func scriptURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "py")
    }

    static func exampleConfiguration() throws -> AppStoreReleaseConfiguration {
        guard let url = Bundle.main.url(
            forResource: "app_store_connect.example",
            withExtension: "json"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var configuration = try load(from: url)
        configuration.importSettings.localizationsRoot = "localizations"
        configuration.upload.localizationsRoot = "localizations"
        return configuration
    }

    static func load(from url: URL) throws -> AppStoreReleaseConfiguration {
        try JSONDecoder().decode(
            AppStoreReleaseConfiguration.self,
            from: Data(contentsOf: url)
        )
    }

    static func save(_ configuration: AppStoreReleaseConfiguration, to url: URL) throws {
        try encodedData(configuration).write(to: url, options: .atomic)
    }

    static func encodedData(_ configuration: AppStoreReleaseConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        return data
    }

    static func resolvedDirectory(_ path: String, relativeTo configURL: URL) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath, isDirectory: true)
        }
        return configURL.deletingLastPathComponent()
            .appending(path: expandedPath, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    static func prepareConfiguration(
        storageDirectory: URL = storageDirectoryURL
    ) throws -> (configuration: AppStoreReleaseConfiguration, isFirstUse: Bool) {
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = configURL(storageDirectory: storageDirectory)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return (try load(from: destinationURL), false)
        }

        try save(.empty, to: destinationURL)
        return (.empty, true)
    }

    static func normalizedImportedConfiguration(
        _ configuration: AppStoreReleaseConfiguration
    ) -> AppStoreReleaseConfiguration {
        var normalized = configuration
        if !normalized.importSettings.localizationsRoot.hasPrefix("/") {
            normalized.importSettings.localizationsRoot = "localizations"
        }
        if !normalized.upload.localizationsRoot.hasPrefix("/") {
            normalized.upload.localizationsRoot = "localizations"
        }
        if !normalized.upload.screenshotsRoot.isEmpty,
           !normalized.upload.screenshotsRoot.hasPrefix("/") {
            normalized.upload.screenshotsRoot = "screenshots"
        }
        return normalized
    }
}

struct AppStoreMaterial: Identifiable, Equatable {
    let locale: String
    let content: String

    var id: String { locale }
}

enum AppStoreMaterialLoader {
    static func load(from rootURL: URL) throws -> [AppStoreMaterial] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { localeURL -> AppStoreMaterial? in
            let metadataURL = localeURL.appending(path: "metadata.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
            let data = try Data(contentsOf: metadataURL)
            let object = try JSONSerialization.jsonObject(with: data)
            let formattedData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return AppStoreMaterial(
                locale: localeURL.lastPathComponent,
                content: String(decoding: formattedData, as: UTF8.self)
            )
        }
        .sorted { $0.locale.localizedStandardCompare($1.locale) == .orderedAscending }
    }
}
