import Foundation
import Security

struct AppSettings: Codable, Equatable, Sendable {
    var obsidianBookmark: Data?
    var summaryProvider: SummaryProviderKind
    var gemmaModel: String
    var ollamaEndpoint: String
    var ollamaModel: String
    var whisperModel: String
    var saveSummary: Bool
    var saveTranscript: Bool
    var keepOriginalAudio: Bool
    var deleteTemporaryFiles: Bool
    init(obsidianBookmark: Data?, summaryProvider: SummaryProviderKind, gemmaModel: String, ollamaEndpoint: String, ollamaModel: String, whisperModel: String, saveSummary: Bool, saveTranscript: Bool, keepOriginalAudio: Bool, deleteTemporaryFiles: Bool) { self.obsidianBookmark = obsidianBookmark; self.summaryProvider = summaryProvider; self.gemmaModel = gemmaModel; self.ollamaEndpoint = ollamaEndpoint; self.ollamaModel = ollamaModel; self.whisperModel = whisperModel; self.saveSummary = saveSummary; self.saveTranscript = saveTranscript; self.keepOriginalAudio = keepOriginalAudio; self.deleteTemporaryFiles = deleteTemporaryFiles }
    static let `default` = AppSettings(obsidianBookmark: nil, summaryProvider: .none, gemmaModel: "gemma-4-26b-a4b-it", ollamaEndpoint: "http://localhost:11434", ollamaModel: "gemma3", whisperModel: "openai_whisper-base", saveSummary: false, saveTranscript: true, keepOriginalAudio: false, deleteTemporaryFiles: true)
    enum CodingKeys: String, CodingKey { case obsidianBookmark, summaryProvider, gemmaModel, ollamaEndpoint, ollamaModel, whisperModel, saveSummary, saveTranscript, keepOriginalAudio, deleteTemporaryFiles }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); let d = Self.default; obsidianBookmark = try c.decodeIfPresent(Data.self, forKey: .obsidianBookmark); summaryProvider = try c.decodeIfPresent(SummaryProviderKind.self, forKey: .summaryProvider) ?? d.summaryProvider; gemmaModel = try c.decodeIfPresent(String.self, forKey: .gemmaModel) ?? d.gemmaModel; ollamaEndpoint = try c.decodeIfPresent(String.self, forKey: .ollamaEndpoint) ?? d.ollamaEndpoint; ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel; whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel; saveSummary = try c.decodeIfPresent(Bool.self, forKey: .saveSummary) ?? d.saveSummary; saveTranscript = try c.decodeIfPresent(Bool.self, forKey: .saveTranscript) ?? d.saveTranscript; keepOriginalAudio = try c.decodeIfPresent(Bool.self, forKey: .keepOriginalAudio) ?? d.keepOriginalAudio; deleteTemporaryFiles = try c.decodeIfPresent(Bool.self, forKey: .deleteTemporaryFiles) ?? d.deleteTemporaryFiles }
}

@MainActor final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    private let defaults: UserDefaults
    private let key = "meetingNotes.settings.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { settings = .default; return }
        settings = decoded
    }
    func update(_ mutate: (inout AppSettings) -> Void) { mutate(&settings); if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) } }
    func setObsidianFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        update { $0.obsidianBookmark = bookmark }
    }
    func resolveObsidianFolder() throws -> URL {
        guard let bookmark = settings.obsidianBookmark else { throw SettingsError.folderNotSelected }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { throw SettingsError.staleBookmark }
        return url
    }
}

enum SettingsError: LocalizedError { case folderNotSelected, staleBookmark
    var errorDescription: String? { switch self { case .folderNotSelected: "Choose an Obsidian folder in Settings."; case .staleBookmark: "Obsidian folder access expired; select the folder again." } }
}

protocol KeychainService { func save(_ value: String, account: String) throws; func read(account: String) throws -> String?; func delete(account: String) throws }
struct SystemKeychainService: KeychainService {
    private let service = "com.meetingnotes.app"
    func save(_ value: String, account: String) throws { try delete(account: account); let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: Data(value.utf8)] as CFDictionary, nil); guard status == errSecSuccess else { throw KeychainError.status(status) } }
    func read(account: String) throws -> String? { let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true]; var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item); if status == errSecItemNotFound { return nil }; guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }; return String(data: data, encoding: .utf8) }
    func delete(account: String) throws { let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) } }
}
enum KeychainError: Error { case status(OSStatus) }
