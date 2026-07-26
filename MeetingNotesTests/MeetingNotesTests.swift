import AVFoundation
import XCTest
@testable import MeetingNotes

final class ExportTests: XCTestCase {
    private let service = DefaultObsidianExportService()
    func testTitleSanitizationAndUnicode() { XCTAssertEqual(service.sanitizeTitle("  . A/B: C?  . "), "A B C"); XCTAssertEqual(service.sanitizeTitle("…東京 meeting…"), "…東京 meeting…"); XCTAssertEqual(service.sanitizeTitle(" /\\:*?%|\"<> \n"), "Meeting") }
    func testTitleLengthLimit() { XCTAssertEqual(service.sanitizeTitle(String(repeating: "a", count: 120)).count, 100) }
    func testNumberedSessionFolders() throws { let folder = try temporaryDirectory(); let session = RecordingSession(createdAt: Date(timeIntervalSince1970: 0), title: "Meeting", stage: .exportPending); let request = ExportRequest(session: session, folder: folder, saveTranscript: false, saveSummary: false, keepOriginalAudio: false); let first = try service.export(request); let second = try service.export(request); XCTAssertEqual(first.lastPathComponent, "meeting.md"); XCTAssertEqual(second.lastPathComponent, "meeting.md"); XCTAssertTrue(first.deletingLastPathComponent().lastPathComponent.hasSuffix("Meeting")); XCTAssertTrue(second.deletingLastPathComponent().lastPathComponent.hasSuffix("Meeting (2)")) }
    func testSessionArtifactsAndOrganizedNote() throws { let folder = try temporaryDirectory(); let audio = folder.appendingPathComponent("source.wav"); try Data([0, 1, 2]).write(to: audio); let session = RecordingSession(createdAt: Date(timeIntervalSince1970: 0), duration: 65, title: "Launch", stage: .exportPending, mixedWAVPath: audio.path, transcript: Transcript(text: "hello", segments: [TranscriptSegment(start: 61, end: 62, text: "Hello")]), summary: MeetingSummary(summary: "Done", decisions: ["Ship"], actionItems: [ActionItem(task: "Test", owner: "Kai")], openQuestions: ["When?"], technicalDetails: ["Swift 6"])); let note = try service.export(ExportRequest(session: session, folder: folder, saveTranscript: true, saveSummary: true, keepOriginalAudio: true)); let text = try String(contentsOf: note); XCTAssertTrue(text.contains("[[transcript.md|Transcript]]")); XCTAssertTrue(text.contains("[[audio.wav]]")); XCTAssertTrue(text.contains("## Summary")); XCTAssertTrue(text.contains("- [ ] Test — Kai")); let sessionFolder = note.deletingLastPathComponent(); let transcript = try String(contentsOf: sessionFolder.appendingPathComponent("transcript.md")); XCTAssertTrue(transcript.contains("[00:01:01] Hello")); XCTAssertEqual(try Data(contentsOf: sessionFolder.appendingPathComponent("audio.wav")), Data([0, 1, 2])) }
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

final class EnvironmentSecretsTests: XCTestCase {
    func testDotenvParsing() { let text = "# comment\nGEMMA_API_KEY = 'secret value'\n"; XCTAssertEqual(EnvironmentSecrets.valueForTesting(named: "GEMMA_API_KEY", in: text), "secret value") }
}

@MainActor final class CoordinatorTests: XCTestCase {
    func testStateMachineRejectsSimultaneousStart() async throws { let defaults = UserDefaults(suiteName: UUID().uuidString)!; let settings = SettingsStore(defaults: defaults); settings.update { $0.obsidianBookmark = Data("x".utf8) }; let capture = MockCapture(); let transcription = MockTranscription(); let coordinator = MeetingCoordinator(settings: settings, capture: capture, transcription: transcription, exporter: MockExporter(), recovery: RecoveryStore()); await coordinator.prepareModel(); await coordinator.start(); await coordinator.start(); XCTAssertEqual(capture.starts, 1) }
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
