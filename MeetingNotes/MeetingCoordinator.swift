import AppKit
import Foundation

@MainActor final class MeetingCoordinator: ObservableObject {
    @Published private(set) var state: MeetingState = .idle
    @Published private(set) var modelReady = false
    @Published private(set) var liveTranscript = ""
    @Published private(set) var session: RecordingSession?
    let settings: SettingsStore
    private let capture: AudioCaptureService
    private let transcription: TranscriptionProvider
    private let exporter: ObsidianExportService
    private let recovery: RecoveryStore
    private let keychain: KeychainService
    private var startedAt: Date?
    init(settings: SettingsStore, capture: AudioCaptureService, transcription: TranscriptionProvider, exporter: ObsidianExportService, recovery: RecoveryStore, keychain: KeychainService = SystemKeychainService()) { self.settings = settings; self.capture = capture; self.transcription = transcription; self.exporter = exporter; self.recovery = recovery; self.keychain = keychain; bindCapture() }
    func canStart() async -> Bool { guard modelReady, settings.settings.obsidianBookmark != nil else { return false }; if case .ready = await capture.checkPermissions() { return true }; return false }
    func prepareModel() async { guard state == .idle else { return }; state = .preparing; do { try await transcription.prepare(model: settings.settings.whisperModel) { _ in }; modelReady = true; state = .idle } catch { fail(error.localizedDescription) } }
    func start() async {
        switch state { case .idle, .completed, .recoverableFailure: break; default: return }; state = .preparing
        let permission = await capture.checkPermissions(); guard permission == .ready else { fail("Permissions are required: \(permission)"); return }
        guard modelReady else { fail("Download and prepare the Whisper model before recording."); return }
        do { let new = RecordingSession(); let directory = try await recovery.directory(for: new.id); session = new; liveTranscript = ""; try await recovery.save(new); startedAt = .now; try await capture.start(sessionDirectory: directory, sessionStart: startedAt!); await transcription.startLiveUpdates { [weak self] text in Task { @MainActor in self?.liveTranscript = text } }; state = .recording } catch { fail(error.localizedDescription) }
    }
    func stop() async { guard state == .recording, var current = session else { return }; state = .stopping; do { let result = try await capture.stop(); current.duration = result.duration; current.microphonePath = result.microphoneURL?.path; current.systemPath = result.systemURL?.path; current.mixedWAVPath = result.mixedWAVURL.path; current.stage = .stopped; session = current; try await recovery.save(current); state = .awaitingTitle } catch { fail(error.localizedDescription) } }
    func confirmTitle(_ title: String) async { guard var current = session, state == .awaitingTitle else { return }; current.title = title; current.stage = .transcribing; session = current; try? await recovery.save(current); state = .transcribing; do { let transcript = try await transcription.finalTranscription(fileURL: URL(fileURLWithPath: current.mixedWAVPath!)); current.transcript = transcript; current.stage = .exportPending; session = current; try await recovery.save(current); await summarizeAndExport() } catch { fail(error.localizedDescription) } }
    func retryLastRecording() async { let recovered = await recovery.unfinished().first; guard let current = session ?? recovered else { return }; session = current; if current.transcript.text.isEmpty { await confirmTitle(current.title) } else { await summarizeAndExport() } }
    func openLastNote() { guard let path = session?.exportedNotePath else { return }; NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    private func summarizeAndExport() async { guard var current = session else { return }; if settings.settings.summaryProvider != .none { state = .summarizing; do { current.summary = try await provider().summarize(transcript: current.transcript); current.stage = .exportPending; session = current; try await recovery.save(current) } catch { current.error = error.localizedDescription; current.stage = .exportPending; session = current; try? await recovery.save(current) } }; state = .exporting; do { let folder = try settings.resolveObsidianFolder(); guard folder.startAccessingSecurityScopedResource() else { throw SettingsError.staleBookmark }; defer { folder.stopAccessingSecurityScopedResource() }; let url = try exporter.export(ExportRequest(session: current, folder: folder, saveTranscript: settings.settings.saveTranscript, saveSummary: settings.settings.saveSummary, keepOriginalAudio: settings.settings.keepOriginalAudio)); current.exportedNotePath = url.path; current.stage = .exported; session = current; try await recovery.save(current); try await recovery.cleanup(session: current, deleteTemporaryFiles: settings.settings.deleteTemporaryFiles && !settings.settings.keepOriginalAudio); state = .completed(url) } catch { fail(error.localizedDescription) } }
    private func provider() -> any SummaryProvider { switch settings.settings.summaryProvider { case .none: NoSummaryProvider(); case .ollama: (try? OllamaSummaryProvider(endpoint: settings.settings.ollamaEndpoint, model: settings.settings.ollamaModel)) ?? NoSummaryProvider(); case .gemma: GemmaSummaryProvider(model: settings.settings.gemmaModel, apiKey: (try? keychain.read(account: "gemma-api-key")) ?? "", session: .shared) } }
    private func bindCapture() { capture.onPCM = { [weak self] buffer, _ in self?.transcription.appendLivePCM(buffer) }; capture.onHealth = { [weak self] health in guard case let .degraded(message) = health else { return }; Task { @MainActor in self?.liveTranscript += "\n⚠︎ \(message)" } } }
    private func fail(_ message: String) { if var s = session { s.error = message; s.stage = .failed; session = s; Task { try? await recovery.save(s) } }; state = .recoverableFailure(message) }
}
