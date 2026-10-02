import AVFoundation
import Foundation
import os

/// Continuous microphone capture that writes rolling PCM16/16 kHz/mono WAV chunks.
///
/// The engine keeps running across chunk boundaries (rotation only swaps the file), because
/// watchOS lets a background app *continue* audio I/O but never *start* it. Conversion runs
/// on the tap thread; file writes and rotation run on one serial queue.
final class ChunkedCaptureEngine {
    static let sampleRate = 16000
    static let defaultChunkSeconds: TimeInterval = 30
    static let chunkSecondsDefaultsKey = "omi.watchChunks.chunkSeconds"

    /// Called on the capture queue after a chunk is committed to the store.
    var onChunkCommitted: (@Sendable (WatchChunkMeta) -> Void)?
    /// Called on the capture queue when the engine stops unexpectedly (configuration change).
    var onEngineStopped: (@Sendable (String) -> Void)?

    private let logger = Logger(subsystem: "com.casonclark.omi.watchapp", category: "capture")
    private let store: WatchChunkStore
    private let queue = DispatchQueue(label: "com.casonclark.omi.watch.capture", qos: .userInitiated)
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(ChunkedCaptureEngine.sampleRate),
        channels: 1,
        interleaved: true
    )!

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?

    // Capture-queue state.
    private var writer: WavChunkWriter?
    private var currentChunkId: String?
    private var currentStartMs: Int64 = 0
    private var chunkBytesTarget: Int64 = Int64(ChunkedCaptureEngine.defaultChunkSeconds) * 32000

    private(set) var isRunning = false

    init(store: WatchChunkStore) {
        self.store = store
        setChunkSeconds(UserDefaults.standard.double(forKey: Self.chunkSecondsDefaultsKey))
    }

    /// 10–120 s, default 30 s. Applies from the next chunk.
    func setChunkSeconds(_ seconds: TimeInterval) {
        let clamped = seconds > 0 ? min(120, max(10, seconds)) : Self.defaultChunkSeconds
        let bytes = Int64(clamped * Double(Self.sampleRate) * 2)
        queue.async { self.chunkBytesTarget = bytes }
    }

    /// Recover audio orphaned by a previous crash/kill. Call before `start()`.
    func recoverOrphans() {
        queue.sync { store.recoverOrphanedParts(sampleRate: Self.sampleRate, excluding: currentChunkId) }
    }

    func start() throws {
        guard !isRunning else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "omi.watch.capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone input unavailable"])
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "omi.watch.capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot convert \(inputFormat) to 16 kHz PCM16"])
        }
        self.converter = converter
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let pcm = self.convert(buffer, ratio: ratio) else { return }
            let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            self.queue.async { self.append(pcm, capturedAtMs: capturedAtMs) }
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.warning("audio engine configuration changed; engine stopped")
            self.tearDownEngine()
            self.queue.async {
                self.finalizeCurrentChunk()
                self.onEngineStopped?("configurationChange")
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
            configObserver = nil
            self.converter = nil
            throw error
        }
        self.engine = engine
        isRunning = true
        logger.info("capture started input=\(inputFormat.sampleRate)Hz ch=\(inputFormat.channelCount)")
    }

    /// Stop capture and commit the in-progress chunk.
    func stop() {
        tearDownEngine()
        queue.sync { finalizeCurrentChunk() }
    }

    /// The system already stopped I/O (interruption). Commit what we have.
    func handleInterruptionBegan() {
        tearDownEngine()
        queue.async { self.finalizeCurrentChunk() }
    }

    private func tearDownEngine() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        isRunning = false
    }

    // MARK: - Tap thread

    private func convert(_ buffer: AVAudioPCMBuffer, ratio: Double) -> Data? {
        guard let converter, buffer.frameLength > 0 else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil {
            logger.error("conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    // MARK: - Capture queue

    private func append(_ pcm: Data, capturedAtMs: Int64) {
        if writer == nil {
            // The first sample of this buffer was captured ~buffer-duration before now.
            let bufferMs = Int64(pcm.count) * 1000 / Int64(Self.sampleRate * 2)
            openChunk(startedAtMs: capturedAtMs - bufferMs)
        }
        guard let writer else { return }
        do {
            try writer.append(pcm)
        } catch {
            logger.error("chunk write failed: \(error.localizedDescription, privacy: .public)")
            finalizeCurrentChunk()
            return
        }
        if writer.dataBytes >= chunkBytesTarget {
            finalizeCurrentChunk()
        }
    }

    private func openChunk(startedAtMs: Int64) {
        var startMs = startedAtMs
        // Chunk ids are start-time based; never reuse one (back-to-back restarts within 1 ms).
        while store.load(WatchChunkStore.chunkId(startedAtMs: startMs)) != nil
            || FileManager.default.fileExists(atPath: store.partURL(for: WatchChunkStore.chunkId(startedAtMs: startMs)).path) {
            startMs += 1
        }
        let chunkId = WatchChunkStore.chunkId(startedAtMs: startMs)
        do {
            writer = try WavChunkWriter(url: store.partURL(for: chunkId), sampleRate: Self.sampleRate)
            currentChunkId = chunkId
            currentStartMs = startMs
        } catch {
            logger.error("cannot open chunk \(chunkId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            writer = nil
            currentChunkId = nil
        }
    }

    private func finalizeCurrentChunk() {
        guard let writer, let chunkId = currentChunkId else { return }
        self.writer = nil
        currentChunkId = nil
        do {
            try writer.finish()
        } catch {
            logger.error("chunk finish failed \(chunkId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            _ = try? WavChunkWriter.repairHeader(at: writer.url, sampleRate: Self.sampleRate)
        }
        // Sub-second fragments (e.g. an interruption right after rotation) are not worth a sync job.
        guard writer.dataBytes >= Int64(Self.sampleRate * 2) else {
            try? FileManager.default.removeItem(at: writer.url)
            return
        }
        if let meta = store.commit(chunkId: chunkId, startedAtMs: currentStartMs, dataBytes: writer.dataBytes, sampleRate: Self.sampleRate) {
            onChunkCommitted?(meta)
        }
    }
}
