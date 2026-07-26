import Foundation

actor RecoveryStore {
    let root: URL
    init(fileManager: FileManager = .default) {
        let preferredRoot = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("MeetingNotes/Recordings", isDirectory: true)
        let fallbackRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MeetingNotes/Recordings", isDirectory: true)

        if let preferredRoot, (try? fileManager.createDirectory(at: preferredRoot, withIntermediateDirectories: true)) != nil {
            root = preferredRoot
        } else {
            try? fileManager.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
            root = fallbackRoot
        }
    }
    func directory(for id: UUID) throws -> URL { let url = root.appendingPathComponent(id.uuidString, isDirectory: true); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
    func save(_ session: RecordingSession) throws { let url = try directory(for: session.id).appendingPathComponent("session.json"); let data = try JSONEncoder().encode(session); try data.write(to: url, options: .atomic) }
    func unfinished() -> [RecordingSession] { guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }; return dirs.compactMap { try? Data(contentsOf: $0.appendingPathComponent("session.json")) }.compactMap { try? JSONDecoder().decode(RecordingSession.self, from: $0) }.filter { $0.stage != .exported } }
    func cleanup(session: RecordingSession, deleteTemporaryFiles: Bool) throws { guard deleteTemporaryFiles else { return }; let dir = root.appendingPathComponent(session.id.uuidString); try FileManager.default.removeItem(at: dir) }
}
