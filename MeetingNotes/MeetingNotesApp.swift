import AppKit
import SwiftUI

@main struct MeetingNotesApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var coordinator: MeetingCoordinator
    init() {
        let settings = SettingsStore()
        let recovery = RecoveryStore()
        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: MeetingCoordinator(settings: settings, capture: CombinedAudioCaptureService(), transcription: WhisperKitTranscriptionProvider(), exporter: DefaultObsidianExportService(), recovery: recovery))
    }
    var body: some Scene {
        MenuBarExtra("MeetingNotes", systemImage: "waveform") { MenuContentView(coordinator: coordinator, settings: settings) }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(settings: settings) }
    }
}

private struct MenuContentView: View {
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject var settings: SettingsStore
    @State private var title = "Meeting"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("MeetingNotes").font(.headline); Spacer(); Text(status).foregroundStyle(.secondary) }
            if case .recording = coordinator.state { TimelineView(.periodic(from: .now, by: 1)) { context in Text("Recording \(elapsed(context.date))").monospacedDigit() } }
            if case .awaitingTitle = coordinator.state { TextField("Title", text: $title); Button("Transcribe and Export") { Task { await coordinator.confirmTitle(title) } }.buttonStyle(.borderedProminent) }
            ScrollView { Text(coordinator.liveTranscript.isEmpty ? "Live transcript will appear here." : coordinator.liveTranscript).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).font(.callout) }.frame(height: 180)
            HStack { switch coordinator.state { case .idle, .completed, .recoverableFailure: if !coordinator.modelReady { Button("Download Whisper Model") { Task { await coordinator.prepareModel() } } } else { Button("Start") { Task { await coordinator.start() } }.disabled(settings.settings.obsidianBookmark == nil) }; case .recording: Button("Stop") { Task { await coordinator.stop() } }.buttonStyle(.borderedProminent); default: ProgressView() }; Spacer(); Button("Open Last Note") { coordinator.openLastNote() }.disabled(coordinator.session?.exportedNotePath == nil) }
            if case .recoverableFailure = coordinator.state { Button("Retry Last Recording") { Task { await coordinator.retryLastRecording() } } }
            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                    Label("Quit MeetingNotes", systemImage: "power")
                }
                .keyboardShortcut("q")
            }
        }.padding().frame(width: 380)
    }
    private var status: String { switch coordinator.state { case .idle: "Ready"; case .preparing: "Preparing"; case .recording: "Recording"; case .stopping: "Finalizing audio"; case .awaitingTitle: "Ready to transcribe"; case .transcribing: "Transcribing"; case .summarizing: "Summarizing"; case .exporting: "Exporting"; case .completed: "Exported"; case let .recoverableFailure(error): error } }
    private func elapsed(_ now: Date) -> String { let seconds = Int(now.timeIntervalSince(coordinator.session?.createdAt ?? now)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

private struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var apiKey = ""
    var body: some View { Form {
        Section("Obsidian") { Button("Choose Obsidian Folder…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { try? settings.setObsidianFolder(url) } }; Text(settings.settings.obsidianBookmark == nil ? "No folder selected" : "Folder selected").foregroundStyle(.secondary) }
        Section("Summary") {
            Picker("Provider", selection: summaryProviderBinding) {
                Text("API").tag(SummaryProviderKind.gemma)
                Text("Local").tag(SummaryProviderKind.ollama)
            }
            TextField("API model", text: binding(\.gemmaModel))
            SecureField("API key", text: $apiKey)
            TextField("Local endpoint", text: binding(\.ollamaEndpoint))
            TextField("Local model", text: binding(\.ollamaModel))
        }
        Section("Transcription") { TextField("Whisper model", text: binding(\.whisperModel)) }
        Section("Export") { Toggle("Save Summary", isOn: binding(\.saveSummary)); Toggle("Save Transcript", isOn: binding(\.saveTranscript)); Toggle("Keep Original Audio", isOn: binding(\.keepOriginalAudio)); Toggle("Delete Temporary Files", isOn: binding(\.deleteTemporaryFiles)) }
    }.padding().frame(width: 480).onChange(of: apiKey) { _, value in if !value.isEmpty { try? SystemKeychainService().save(value, account: "gemma-api-key") } } }
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> { Binding(get: { settings.settings[keyPath: keyPath] }, set: { value in settings.update { $0[keyPath: keyPath] = value } }) }
    private var summaryProviderBinding: Binding<SummaryProviderKind> { Binding(get: { settings.settings.summaryProvider == .ollama ? .ollama : .gemma }, set: { provider in settings.update { $0.summaryProvider = provider } }) }
}
