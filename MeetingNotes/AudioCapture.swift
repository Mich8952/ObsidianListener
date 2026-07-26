@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError { case microphonePermission, screenPermission, noInput, noDisplay
    var errorDescription: String? { switch self { case .microphonePermission: "Allow Microphone access in System Settings > Privacy & Security > Microphone."; case .screenPermission: "Allow Screen & System Audio Recording in System Settings > Privacy & Security > Screen & System Audio Recording."; case .noInput: "No microphone input is available."; case .noDisplay: "No display is available for system audio capture." } }
}

/// Concurrent microphone and ScreenCaptureKit system-audio recorder. Both files are normalized to 16 kHz mono Float32 WAV before mixing.
final class CombinedAudioCaptureService: NSObject, AudioCaptureService, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onPCM: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?
    var onHealth: (@Sendable (CaptureHealth) -> Void)?
    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var directory: URL?
    private var sessionStart: Date = .now
    private let io = DispatchQueue(label: "MeetingNotes.capture.io")
    private var maximumTimestamp: TimeInterval = 0
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    override init() { super.init(); NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged), name: .AVAudioEngineConfigurationChange, object: engine) }
    deinit { NotificationCenter.default.removeObserver(self) }
    func checkPermissions() async -> CapturePermission {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneOK: Bool
        if mic == .notDetermined { microphoneOK = await AVCaptureDevice.requestAccess(for: .audio) } else { microphoneOK = mic == .authorized }
        guard microphoneOK else { return .microphoneDenied }
        return CGPreflightScreenCaptureAccess() ? .ready : .screenRecordingDenied
    }
    func start(sessionDirectory: URL, sessionStart: Date) async throws {
        directory = sessionDirectory; self.sessionStart = sessionStart; maximumTimestamp = 0
        guard engine.inputNode.inputFormat(forBus: 0).sampleRate > 0 else { throw CaptureError.noInput }
        let micURL = sessionDirectory.appendingPathComponent("microphone.wav")
        let systemURL = sessionDirectory.appendingPathComponent("system.wav")
        micFile = try AVAudioFile(forWriting: micURL, settings: targetFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        systemFile = try AVAudioFile(forWriting: systemURL, settings: targetFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let input = engine.inputNode; let inputFormat = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, time in self?.writeMicrophone(buffer, timestamp: time) }
        try engine.start()
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareable.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration(); config.capturesAudio = true; config.sampleRate = 16_000; config.channelCount = 1; config.excludesCurrentProcessAudio = true; config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let newStream = SCStream(filter: filter, configuration: config, delegate: self); stream = newStream
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: io)
        try await newStream.startCapture()
    }
    func stop() async throws -> CapturedAudio {
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        if let stream { try? await stream.stopCapture() }; stream = nil
        let microphoneURL = micFile?.url; let systemURL = systemFile?.url; micFile = nil; systemFile = nil
        guard let directory else { throw CaptureError.noInput }
        let mixed = directory.appendingPathComponent("mixed.wav")
        try WavMixer.mix(microphoneURL, systemURL, to: mixed)
        return CapturedAudio(microphoneURL: microphoneURL, systemURL: systemURL, mixedWAVURL: mixed, duration: maximumTimestamp)
    }
    private func writeMicrophone(_ buffer: AVAudioPCMBuffer, timestamp: AVAudioTime) { let t = Date.now.timeIntervalSince(sessionStart); write(buffer, to: micFile, timestamp: t) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) { guard type == .audio, let pcm = Self.pcm(from: sampleBuffer, target: targetFormat) else { return }; let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)); write(pcm, to: systemFile, timestamp: seconds.isFinite ? seconds : Date.now.timeIntervalSince(sessionStart)) }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { onHealth?(.degraded("System audio stopped: \(error.localizedDescription). Microphone recording continues.")) }
    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile?, timestamp: TimeInterval) { io.async { [weak self] in guard let self, let file else { return }; do { try file.write(from: buffer); self.maximumTimestamp = max(self.maximumTimestamp, timestamp + Double(buffer.frameLength) / 16_000); self.onPCM?(buffer, timestamp) } catch { self.onHealth?(.degraded("Audio source write failed: \(error.localizedDescription)")) } } }
    @objc private func configurationChanged() { guard engine.isRunning else { return }; do { engine.stop(); try engine.start(); onHealth?(.healthy) } catch { onHealth?(.degraded("Microphone device changed and could not restart. System audio continues.")) } }
    private static func pcm(from sampleBuffer: CMSampleBuffer, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer), let source = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: description), frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))) else { return nil }; let format = AVAudioFormat(cmAudioFormatDescription: description)
        source.frameLength = source.frameCapacity
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }; var length = 0; var data: UnsafeMutablePointer<Int8>?; guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data) == noErr, let data else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList); guard let dst = abl.first?.mData else { return nil }; memcpy(dst, data, min(length, Int(source.frameCapacity) * Int(format.streamDescription.pointee.mBytesPerFrame)))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * target.sampleRate / format.sampleRate)), let converter = AVAudioConverter(from: format, to: target) else { return nil }
        let input = ConverterInput(source); var error: NSError?; let status = converter.convert(to: output, error: &error) { _, outStatus in if input.provided { outStatus.pointee = .noDataNow; return nil }; input.provided = true; outStatus.pointee = .haveData; return input.buffer }; return status != .error ? output : nil
    }
}

private final class ConverterInput: @unchecked Sendable { let buffer: AVAudioPCMBuffer; var provided = false; init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer } }

enum WavMixer {
    static func mix(_ first: URL?, _ second: URL?, to output: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let outputFile = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let files = try [first, second].compactMap { url -> AVAudioFile? in guard let url else { return nil }; return try AVAudioFile(forReading: url) }
        let maxFrames = files.map { $0.length }.max() ?? 0
        let chunk: AVAudioFrameCount = 4096; var position: AVAudioFramePosition = 0
        while position < maxFrames { let count = AVAudioFrameCount(min(Int64(chunk), maxFrames - position)); guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }; mixed.frameLength = count; for file in files { file.framePosition = position; guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { continue }; try file.read(into: b, frameCount: count); guard let dest = mixed.floatChannelData?[0], let src = b.floatChannelData?[0] else { continue }; for i in 0..<Int(b.frameLength) { dest[i] += src[i] } }; if let samples = mixed.floatChannelData?[0] { for i in 0..<Int(count) { samples[i] = tanh(samples[i]) } }; try outputFile.write(from: mixed); position += AVAudioFramePosition(count) }
    }
}
