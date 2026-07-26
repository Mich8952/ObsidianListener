import Foundation

struct Transcript: Codable, Equatable, Sendable {
    var text: String
    var segments: [TranscriptSegment]
    static let empty = Transcript(text: "", segments: [])
}

struct TranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id; self.start = start; self.end = end; self.text = text
    }
}

struct ActionItem: Codable, Equatable, Sendable {
    var task: String
    var owner: String?
}

struct MeetingSummary: Codable, Equatable, Sendable {
    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var technicalDetails: [String]
}

enum PipelineStage: String, Codable, Sendable { case recording, stopped, transcribing, summarizing, exportPending, exported, failed }

struct RecordingSession: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var title: String
    var stage: PipelineStage
    var microphonePath: String?
    var systemPath: String?
    var mixedWAVPath: String?
    var transcript: Transcript
    var summary: MeetingSummary?
    var error: String?
    var exportedNotePath: String?
    init(id: UUID = UUID(), createdAt: Date = .now, duration: TimeInterval = 0, title: String = "Meeting", stage: PipelineStage = .recording, microphonePath: String? = nil, systemPath: String? = nil, mixedWAVPath: String? = nil, transcript: Transcript = .empty, summary: MeetingSummary? = nil, error: String? = nil, exportedNotePath: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.duration = duration; self.title = title; self.stage = stage; self.microphonePath = microphonePath; self.systemPath = systemPath; self.mixedWAVPath = mixedWAVPath; self.transcript = transcript; self.summary = summary; self.error = error; self.exportedNotePath = exportedNotePath
    }
}

struct ExportRequest: Sendable {
    var session: RecordingSession
    var folder: URL
    var saveTranscript: Bool
    var saveSummary: Bool
    var keepOriginalAudio: Bool
}

enum MeetingState: Equatable, Sendable { case idle, preparing, recording, stopping, awaitingTitle, transcribing, summarizing, exporting, completed(URL), recoverableFailure(String) }

enum SummaryProviderKind: String, Codable, CaseIterable, Sendable { case none, gemma, ollama }
