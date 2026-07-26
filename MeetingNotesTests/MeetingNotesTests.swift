import AVFoundation
import XCTest
@testable import MeetingNotes

final class ExportTests: XCTestCase {
    private let service = DefaultObsidianExportService()
    func testTitleSanitizationAndUnicode() { XCTAssertEqual(service.sanitizeTitle("  . A/B: C?  . "), "A B C"); XCTAssertEqual(service.sanitizeTitle("…東京 meeting…"), "…東京 meeting…"); XCTAssertEqual(service.sanitizeTitle(" /\\:*?%|\"<> \n"), "Meeting") }
    func testTitleLengthLimit() { XCTAssertEqual(service.sanitizeTitle(String(repeating: "a", count: 120)).count, 100) }
    func testNumberedCollisions() throws { let folder = try temporaryDirectory(); let session = RecordingSession(createdAt: Date(timeIntervalSince1970: 0), title: "Meeting", stage: .exportPending); let request = ExportRequest(session: session, folder: folder, saveTranscript: false, saveSummary: false, keepOriginalAudio: false); let first = try service.export(request); let second = try service.export(request); XCTAssertTrue(first.lastPathComponent.hasSuffix("Meeting.md")); XCTAssertTrue(second.lastPathComponent.hasSuffix("Meeting (2).md")) }
    func testMarkdownAllSectionsAndTimestamps() { var session = RecordingSession(createdAt: Date(timeIntervalSince1970: 0), duration: 65, title: "Launch", stage: .exportPending, transcript: Transcript(text: "hello", segments: [TranscriptSegment(start: 61, end: 62, text: "Hello")]), summary: MeetingSummary(summary: "Done", decisions: ["Ship"], actionItems: [ActionItem(task: "Test", owner: "Kai")], openQuestions: ["When?"], technicalDetails: ["Swift 6"])); let text = service.renderMarkdown(session: session, audioFileName: "audio.wav", saveTranscript: true, saveSummary: true); XCTAssertTrue(text.contains("---\ntitle: \"Launch\"")); XCTAssertTrue(text.contains("[[audio.wav]]")); XCTAssertTrue(text.contains("## Summary")); XCTAssertTrue(text.contains("[00:01:01] Hello")); session.summary = nil; XCTAssertFalse(service.renderMarkdown(session: session, audioFileName: nil, saveTranscript: false, saveSummary: false).contains("## Transcript")) }
}

final class SummaryTests: XCTestCase {
    func testValidAndFencedSummaryJSON() throws { let json = """
```json
{"summary":"x","decisions":[],"actionItems":[{"task":"do","owner":"A"}],"openQuestions":[],"technicalDetails":[]}
```
"""; XCTAssertEqual(try SummaryJSON.parse(json).actionItems.first?.task, "do") }
    func testInvalidSummariesFail() { XCTAssertThrowsError(try SummaryJSON.parse("{\"summary\":\"x\"}")); XCTAssertThrowsError(try SummaryJSON.parse("{\"summary\":\"x\",\"decisions\":[],\"actionItems\":[{\"task\":\"\"}],\"openQuestions\":[],\"technicalDetails\":[]}")) }
}

final class SettingsTests: XCTestCase {
    func testDefaultsAndMigrationSafeDecoding() throws { XCTAssertEqual(AppSettings.default.ollamaEndpoint, "http://localhost:11434"); let old = Data("{\"saveTranscript\":false}".utf8); let decoded = try JSONDecoder().decode(AppSettings.self, from: old); XCTAssertFalse(decoded.saveTranscript); XCTAssertEqual(decoded.whisperModel, "openai_whisper-base"); XCTAssertTrue(decoded.deleteTemporaryFiles) }
    func testMigratesPreviousGemmaDefault() throws { let old = Data("{\"gemmaModel\":\"gemma-4-26b-a4b-it\"}".utf8); let decoded = try JSONDecoder().decode(AppSettings.self, from: old); XCTAssertEqual(decoded.gemmaModel, AppSettings.defaultGemmaModel) }
    @MainActor func testSettingsRoundTripIsIsolated() { let defaults = UserDefaults(suiteName: UUID().uuidString)!; let store = SettingsStore(defaults: defaults); store.update { $0.ollamaModel = "qwen" }; XCTAssertEqual(SettingsStore(defaults: defaults).settings.ollamaModel, "qwen") }
}

@MainActor final class CoordinatorTests: XCTestCase {
    func testStateMachineRejectsSimultaneousStart() async throws { let defaults = UserDefaults(suiteName: UUID().uuidString)!; let settings = SettingsStore(defaults: defaults); settings.update { $0.obsidianBookmark = Data("x".utf8) }; let capture = MockCapture(); let transcription = MockTranscription(); let coordinator = MeetingCoordinator(settings: settings, capture: capture, transcription: transcription, exporter: MockExporter(), recovery: try RecoveryStore()); await coordinator.prepareModel(); await coordinator.start(); await coordinator.start(); XCTAssertEqual(capture.starts, 1) }
}

private final class MockCapture: AudioCaptureService, @unchecked Sendable {
    var onPCM: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?; var onHealth: (@Sendable (CaptureHealth) -> Void)?; var starts = 0
    func checkPermissions() async -> CapturePermission { .ready }
    func start(sessionDirectory: URL, sessionStart: Date) async throws { starts += 1 }
    func stop() async throws -> CapturedAudio { CapturedAudio(microphoneURL: nil, systemURL: nil, mixedWAVURL: URL(fileURLWithPath: "/tmp/a.wav"), duration: 0) }
}
private final class MockTranscription: TranscriptionProvider, @unchecked Sendable { func prepare(model: String, progress: @escaping @Sendable (Double) -> Void) async throws { }; func startLiveUpdates(_ handler: @escaping @Sendable (String) -> Void) async { }; func appendLivePCM(_ buffer: AVAudioPCMBuffer) { }; func finalTranscription(fileURL: URL) async throws -> Transcript { .empty } }
private final class MockExporter: ObsidianExportService { func validateFolder(_ url: URL) throws { }; func export(_ request: ExportRequest) throws -> URL { request.folder.appendingPathComponent("x.md") } }
private func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
