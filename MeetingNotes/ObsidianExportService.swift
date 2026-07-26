import Foundation

final class DefaultObsidianExportService: ObsidianExportService {
    private let queue = DispatchQueue(label: "MeetingNotes.export")
    func validateFolder(_ url: URL) throws { var directory: ObjCBool = false; guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw ExportError.invalidFolder } }
    func export(_ request: ExportRequest) throws -> URL { try queue.sync { try exportLocked(request) } }
    private func exportLocked(_ request: ExportRequest) throws -> URL {
        try validateFolder(request.folder)
        let stem = filenameStem(date: request.session.createdAt, title: request.session.title)
        let sessionFolder = collisionFreeDirectory(in: request.folder, stem: stem)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: false)
        let noteURL = sessionFolder.appendingPathComponent("meeting.md")
        var audioName: String?
        if request.keepOriginalAudio, let path = request.session.mixedWAVPath {
            let audioURL = sessionFolder.appendingPathComponent("audio.wav")
            try atomicCopy(from: URL(fileURLWithPath: path), to: audioURL)
            audioName = audioURL.lastPathComponent
        }
        if request.saveTranscript {
            let transcriptURL = sessionFolder.appendingPathComponent("transcript.md")
            try atomicWrite(renderTranscriptMarkdown(session: request.session).data(using: .utf8)!, to: transcriptURL)
        }
        let markdown = renderMarkdown(session: request.session, audioFileName: audioName, saveTranscript: request.saveTranscript, saveSummary: request.saveSummary)
        try atomicWrite(markdown.data(using: .utf8)!, to: noteURL)
        return noteURL
    }
    func filenameStem(date: Date, title: String) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd HHmm"; return "\(f.string(from: date)) - \(sanitizeTitle(title))" }
    func sanitizeTitle(_ value: String) -> String { let invalid = CharacterSet(charactersIn: "/\\\\:?%*|\"<>").union(.controlCharacters); var clean = value.components(separatedBy: invalid).joined(separator: " "); clean = clean.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))); if clean.isEmpty { clean = "Meeting" }; return String(clean.prefix(100)) }
    private func collisionFreeDirectory(in folder: URL, stem: String) -> URL { var n = 1; while true { let suffix = n == 1 ? "" : " (\(n))"; let url = folder.appendingPathComponent(stem + suffix, isDirectory: true); if !FileManager.default.fileExists(atPath: url.path) { return url }; n += 1 } }
    func renderMarkdown(session: RecordingSession, audioFileName: String?, saveTranscript: Bool, saveSummary: Bool) -> String {
        let iso = ISO8601DateFormatter().string(from: session.createdAt)
        var out = "---\ntitle: \"\(yaml(session.title))\"\ncreated: \(iso)\nduration_seconds: \(Int(session.duration))\n---\n\n# \(session.title)\n"
        if let audioFileName { out += "\n[[\(audioFileName)]]\n" }
        if saveTranscript { out += "\n[[transcript.md|Transcript]]\n" }
        if saveSummary, let s = session.summary { out += "\n## Summary\n\n\(s.summary)\n\n## Decisions\n\n\(bullets(s.decisions))\n\n## To-Dos\n\n\(tasks(s.actionItems))\n\n## Open Questions\n\n\(bullets(s.openQuestions))\n\n## Technical Details\n\n\(bullets(s.technicalDetails))\n" } else { out += "\n## Summary\n\nNo summary was requested for this session.\n" }
        return out
    }
    func renderTranscriptMarkdown(session: RecordingSession) -> String { let iso = ISO8601DateFormatter().string(from: session.createdAt); let segments = session.transcript.segments.isEmpty ? session.transcript.text : session.transcript.segments.map { "[\(clock($0.start))] \($0.text)" }.joined(separator: "\n"); return "---\ntitle: \"\(yaml(session.title)) — Transcript\"\ncreated: \(iso)\n---\n\n# \(session.title) Transcript\n\n\(segments)\n" }
    private func yaml(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private func bullets(_ a: [String]) -> String { a.isEmpty ? "- None" : a.map { "- \($0)" }.joined(separator: "\n") }
    private func tasks(_ a: [ActionItem]) -> String { a.isEmpty ? "- None" : a.map { "- [ ] \($0.task)" + ($0.owner.map { " — \($0)" } ?? "") }.joined(separator: "\n") }
    private func clock(_ t: TimeInterval) -> String { String(format: "%02d:%02d:%02d", Int(t) / 3600, Int(t) / 60 % 60, Int(t) % 60) }
    private func atomicWrite(_ data: Data, to url: URL) throws { let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp"); try data.write(to: temp, options: .atomic); try FileManager.default.moveItem(at: temp, to: url) }
    private func atomicCopy(from source: URL, to destination: URL) throws { let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp"); try FileManager.default.copyItem(at: source, to: temp); try FileManager.default.moveItem(at: temp, to: destination) }
}
enum ExportError: LocalizedError { case invalidFolder; var errorDescription: String? { "The selected Obsidian folder is unavailable." } }
