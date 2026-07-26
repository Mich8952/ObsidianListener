import AVFoundation
import Foundation
import os
import WhisperKit

/// Thin adapter keeps WhisperKit's evolving streaming API out of the coordinator. Final transcription always replaces provisional text.
final class WhisperKitTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private struct LiveState { var handler: (@Sendable (String) -> Void)?; var samples: [Float] = []; var submittedSamples = 0; var inFlight = false }
    private let liveState = OSAllocatedUnfairLock(initialState: LiveState())
    func prepare(model: String, progress: @escaping @Sendable (Double) -> Void) async throws { progress(0); whisperKit = try await WhisperKit(model: model); progress(1) }
    func startLiveUpdates(_ handler: @escaping @Sendable (String) -> Void) async { liveState.withLock { $0.handler = handler; $0.samples = []; $0.submittedSamples = 0; $0.inFlight = false } }
    func appendLivePCM(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength); let new = Array(UnsafeBufferPointer(start: data, count: count))
        let snapshot: [Float]? = liveState.withLock { state in
            state.samples.append(contentsOf: new)
            // Re-transcribe the rolling 30 seconds every four seconds. WhisperKit's file pass remains authoritative after Stop.
            guard !state.inFlight, state.samples.count - state.submittedSamples >= 64_000 else { return nil }
            state.inFlight = true; state.submittedSamples = state.samples.count
            return Array(state.samples.suffix(480_000))
        }
        if let snapshot { Task { [weak self] in await self?.transcribeLive(snapshot) } }
    }
    private func transcribeLive(_ samples: [Float]) async {
        defer { liveState.withLock { $0.inFlight = false } }
        guard let whisperKit else { return }
        let result = await whisperKit.transcribe(audioArrays: [samples])
        let text = result.first??.map(\.text).joined(separator: " ") ?? ""
        let callback = liveState.withLock { $0.handler }
        if !text.isEmpty { callback?(text) }
    }
    func finalTranscription(fileURL: URL) async throws -> Transcript { guard let whisperKit else { throw NSError(domain: "MeetingNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Whisper model is not ready."]) }; let results = try await whisperKit.transcribe(audioPath: fileURL.path); let segments = results.flatMap(\.segments).map { TranscriptSegment(start: TimeInterval($0.start), end: TimeInterval($0.end), text: $0.text) }; return Transcript(text: results.map(\.text).joined(separator: " "), segments: segments) }
}
