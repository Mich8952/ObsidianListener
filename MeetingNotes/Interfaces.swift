@preconcurrency import AVFoundation
import Foundation

enum CaptureHealth: Sendable, Equatable { case healthy, degraded(String), unavailable(String) }
enum CapturePermission: Sendable, Equatable { case ready, microphoneDenied, screenRecordingDenied, unavailable(String) }

protocol AudioCaptureService: AnyObject, Sendable {
    var onPCM: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)? { get set }
    var onHealth: (@Sendable (CaptureHealth) -> Void)? { get set }
    func checkPermissions() async -> CapturePermission
    func start(sessionDirectory: URL, sessionStart: Date) async throws
    func stop() async throws -> CapturedAudio
}

struct CapturedAudio: Sendable { var microphoneURL: URL?; var systemURL: URL?; var mixedWAVURL: URL; var duration: TimeInterval }

protocol TranscriptionProvider: AnyObject, Sendable {
    func prepare(model: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func startLiveUpdates(_ handler: @escaping @Sendable (String) -> Void) async
    func appendLivePCM(_ buffer: AVAudioPCMBuffer)
    func finalTranscription(fileURL: URL) async throws -> Transcript
}

protocol SummaryProvider: Sendable { var identity: String { get }; func summarize(transcript: Transcript) async throws -> MeetingSummary? }
protocol ObsidianExportService: AnyObject { func validateFolder(_ url: URL) throws; func export(_ request: ExportRequest) throws -> URL }
