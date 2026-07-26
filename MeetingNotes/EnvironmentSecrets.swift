import Foundation

/// Development-friendly secret loading. Production credentials entered in Settings remain in Keychain.
enum EnvironmentSecrets {
    static func gemmaAPIKey() -> String? {
        if let value = ProcessInfo.processInfo.environment["GEMMA_API_KEY"], !value.isEmpty { return value }
        for url in dotenvURLs() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let value = valueForTesting(named: "GEMMA_API_KEY", in: text), !value.isEmpty { return value }
        }
        return nil
    }
    static func dotenvURLs(fileManager: FileManager = .default) -> [URL] {
        var urls = [URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".env")]
        if let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) { urls.append(support.appendingPathComponent("MeetingNotes/.env")) }
        return urls
    }
    static func valueForTesting(named name: String, in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            return line[line.index(after: equal)...].trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'"))
        }
        return nil
    }
}
