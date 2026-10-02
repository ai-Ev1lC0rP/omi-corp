import Foundation
import os

/// Metadata for one finished audio chunk on the watch. Persisted as a JSON sidecar
/// (`<chunkId>.json`) next to the audio (`<chunkId>.wav`); the sidecar is the commit
/// marker, so a crash mid-write never produces a half-registered chunk.
struct WatchChunkMeta: Codable, Equatable {
    static let formatWavPcm16 = "wav_pcm16"

    let chunkId: String
    let fileName: String
    /// Wall-clock time of the first sample, unix milliseconds.
    let startedAtMs: Int64
    var durationMs: Int64
    let sampleRate: Int
    let channels: Int
    let format: String
    var byteCount: Int64
    /// Last time the chunk was handed to `WCSession.transferFile`.
    var transferQueuedAt: Date?
    /// Last time WatchConnectivity reported the file delivered to the phone.
    var transferDeliveredAt: Date?
    var transferAttempts: Int

    /// Dictionary sent as `transferFile` metadata (property-list types only).
    var transferMetadata: [String: Any] {
        [
            "kind": "omiWatchChunk",
            "chunkId": chunkId,
            "fileName": fileName,
            "startedAtMs": startedAtMs,
            "durationMs": durationMs,
            "sampleRate": sampleRate,
            "channels": channels,
            "format": format,
            "byteCount": byteCount,
        ]
    }
}

/// Minimal streaming WAV (PCM16 mono) writer. The 44-byte header is written up front with
/// zero sizes and patched on `finish()`; `repairHeader(at:)` recovers a file left behind by
/// a crash or kill, so audio already on disk is never lost.
final class WavChunkWriter {
    static let headerSize: Int64 = 44

    let url: URL
    let sampleRate: Int
    private let handle: FileHandle
    private(set) var dataBytes: Int64 = 0

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: WavChunkWriter.header(dataBytes: 0, sampleRate: sampleRate))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ pcm: Data) throws {
        guard !pcm.isEmpty else { return }
        try handle.write(contentsOf: pcm)
        dataBytes += Int64(pcm.count)
    }

    var durationMs: Int64 {
        sampleRate > 0 ? dataBytes * 1000 / Int64(sampleRate * 2) : 0
    }

    func finish() throws {
        try WavChunkWriter.patchHeader(handle: handle, dataBytes: dataBytes, sampleRate: sampleRate)
        try handle.synchronize()
        try handle.close()
    }

    /// Patch the header of an orphaned `.part` file from its size. Returns the PCM byte count.
    @discardableResult
    static func repairHeader(at url: URL, sampleRate: Int) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var dataBytes = max(0, size - headerSize)
        dataBytes -= dataBytes % 2
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(headerSize + dataBytes))
        try patchHeader(handle: handle, dataBytes: dataBytes, sampleRate: sampleRate)
        return dataBytes
    }

    private static func patchHeader(handle: FileHandle, dataBytes: Int64, sampleRate: Int) throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataBytes: dataBytes, sampleRate: sampleRate))
    }

    static func header(dataBytes: Int64, sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let clampedData = UInt32(clamping: dataBytes)
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 &+ clampedData)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)  // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        append32(clampedData)
        return data
    }
}

/// On-watch chunk inventory: finished chunks wait here until the phone acknowledges that
/// they were uploaded and transcribed. Storage is capped; past the cap the oldest chunks
/// are dropped (and counted) so continuous capture never fills the watch.
final class WatchChunkStore {
    static let defaultMaxStorageBytes: Int64 = 500 * 1024 * 1024  // ~8.7 h of PCM16 16 kHz
    static let maxStorageDefaultsKey = "omi.watchChunks.maxStorageBytes"
    static let droppedCountDefaultsKey = "omi.watchChunks.droppedCount"
    static let partExtension = "part"

    private let logger = Logger(subsystem: "com.casonclark.omi.watchapp", category: "chunks")
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    let directory: URL

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        self.directory = directory ?? base.appendingPathComponent("omi_chunks", isDirectory: true)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Keep chunks out of iCloud/device backups; they are transient.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = self.directory
        try? dir.setResourceValues(values)
    }

    var maxStorageBytes: Int64 {
        let configured = defaults.object(forKey: Self.maxStorageDefaultsKey) as? NSNumber
        let value = configured?.int64Value ?? Self.defaultMaxStorageBytes
        return max(16 * 1024 * 1024, value)
    }

    var droppedChunkCount: Int { defaults.integer(forKey: Self.droppedCountDefaultsKey) }

    static func chunkId(startedAtMs: Int64) -> String { "omiwatch_\(startedAtMs)" }

    func audioURL(for chunkId: String) -> URL { directory.appendingPathComponent("\(chunkId).wav") }
    func partURL(for chunkId: String) -> URL { audioURL(for: chunkId).appendingPathExtension(Self.partExtension) }
    func metaURL(for chunkId: String) -> URL { directory.appendingPathComponent("\(chunkId).json") }

    /// Promote a finished `.wav.part` into a registered chunk.
    @discardableResult
    func commit(chunkId: String, startedAtMs: Int64, dataBytes: Int64, sampleRate: Int) -> WatchChunkMeta? {
        let part = partURL(for: chunkId)
        let audio = audioURL(for: chunkId)
        do {
            if dataBytes <= 0 {
                try? fileManager.removeItem(at: part)
                return nil
            }
            if fileManager.fileExists(atPath: audio.path) { try fileManager.removeItem(at: audio) }
            try fileManager.moveItem(at: part, to: audio)
            let meta = WatchChunkMeta(
                chunkId: chunkId,
                fileName: audio.lastPathComponent,
                startedAtMs: startedAtMs,
                durationMs: sampleRate > 0 ? dataBytes * 1000 / Int64(sampleRate * 2) : 0,
                sampleRate: sampleRate,
                channels: 1,
                format: WatchChunkMeta.formatWavPcm16,
                byteCount: dataBytes + WavChunkWriter.headerSize,
                transferQueuedAt: nil,
                transferDeliveredAt: nil,
                transferAttempts: 0
            )
            try save(meta)
            logger.info("chunk committed \(chunkId, privacy: .public) durationMs=\(meta.durationMs)")
            return meta
        } catch {
            logger.error("chunk commit failed \(chunkId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ meta: WatchChunkMeta) throws {
        let data = try encoder.encode(meta)
        try data.write(to: metaURL(for: meta.chunkId), options: .atomic)
    }

    func update(_ chunkId: String, _ mutate: (inout WatchChunkMeta) -> Void) {
        guard var meta = load(chunkId) else { return }
        mutate(&meta)
        try? save(meta)
    }

    func load(_ chunkId: String) -> WatchChunkMeta? {
        guard let data = try? Data(contentsOf: metaURL(for: chunkId)) else { return nil }
        return try? decoder.decode(WatchChunkMeta.self, from: data)
    }

    /// All committed chunks, oldest first.
    func pendingChunks() -> [WatchChunkMeta] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { load(String($0.dropLast(5))) }
            .filter { fileManager.fileExists(atPath: audioURL(for: $0.chunkId).path) }
            .sorted { $0.startedAtMs < $1.startedAtMs }
    }

    func pendingBytes() -> Int64 { pendingChunks().reduce(0) { $0 + $1.byteCount } }

    /// Remove acknowledged chunks. Returns how many were deleted.
    @discardableResult
    func delete(chunkIds: [String]) -> Int {
        var deleted = 0
        for chunkId in chunkIds where isSafeChunkId(chunkId) {
            let hadAudio = fileManager.fileExists(atPath: audioURL(for: chunkId).path)
            try? fileManager.removeItem(at: audioURL(for: chunkId))
            try? fileManager.removeItem(at: metaURL(for: chunkId))
            if hadAudio { deleted += 1 }
        }
        if deleted > 0 { logger.info("deleted \(deleted) acknowledged chunk(s)") }
        return deleted
    }

    /// Finalize `.part` files orphaned by a crash/kill so their audio still syncs.
    func recoverOrphanedParts(sampleRate: Int, excluding activeChunkId: String?) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".wav.\(Self.partExtension)") {
            let chunkId = String(name.dropLast(".wav.\(Self.partExtension)".count))
            guard chunkId != activeChunkId, isSafeChunkId(chunkId),
                  let startedAtMs = Int64(chunkId.replacingOccurrences(of: "omiwatch_", with: "")) else { continue }
            do {
                let dataBytes = try WavChunkWriter.repairHeader(at: partURL(for: chunkId), sampleRate: sampleRate)
                commit(chunkId: chunkId, startedAtMs: startedAtMs, dataBytes: dataBytes, sampleRate: sampleRate)
                logger.info("recovered orphaned chunk \(chunkId, privacy: .public)")
            } catch {
                logger.error("orphan recovery failed \(chunkId, privacy: .public)")
                try? fileManager.removeItem(at: partURL(for: chunkId))
            }
        }
    }

    /// Drop the oldest chunks until pending storage fits under the cap. Returns dropped ids.
    @discardableResult
    func enforceStorageCap() -> [String] {
        var chunks = pendingChunks()
        var total = chunks.reduce(Int64(0)) { $0 + $1.byteCount }
        let cap = maxStorageBytes
        var dropped: [String] = []
        while total > cap, !chunks.isEmpty {
            let oldest = chunks.removeFirst()
            total -= oldest.byteCount
            dropped.append(oldest.chunkId)
        }
        if !dropped.isEmpty {
            delete(chunkIds: dropped)
            defaults.set(droppedChunkCount + dropped.count, forKey: Self.droppedCountDefaultsKey)
            logger.warning("storage cap \(cap) bytes exceeded; dropped \(dropped.count) oldest unsynced chunk(s): \(dropped.joined(separator: ","), privacy: .public)")
        }
        return dropped
    }

    private func isSafeChunkId(_ chunkId: String) -> Bool {
        !chunkId.isEmpty && chunkId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
