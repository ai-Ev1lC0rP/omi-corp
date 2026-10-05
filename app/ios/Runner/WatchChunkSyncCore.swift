import Foundation

// Foundation-only pieces of the phone-side Apple Watch chunk sync, kept free of UIKit,
// Flutter, Firebase and WatchConnectivity so `app/ios/test/watch_chunk_sync_core_test.rb`
// can compile and exercise them with plain `swiftc`.
//
// Ownership: on iOS the native layer (WatchChunkSync.swift) is the single owner of watch
// chunk upload, server-job confirmation and the watch ack. Dart only passes configuration
// and nudges. One persisted state file holds dedupe by chunk id, so a chunk is never
// uploaded twice by two schedulers.

/// A chunk persisted by `WatchChunkInbox`: `<chunkId>.wav` plus `<chunkId>.json`.
struct WatchStoredChunk: Equatable {
    let chunkId: String
    let startedAtMs: Int64
    let durationMs: Int64
    let sampleRate: Int
    let channels: Int
    let audioURL: URL
    let sidecarURL: URL

    /// Parses the sidecar written by `WatchChunkInbox.receive`. Missing or zero
    /// timestamps fall back to `fallbackStartMs` (the file's modification time).
    static func from(sidecar: URL, directory: URL, fallbackStartMs: Int64) -> WatchStoredChunk? {
        guard let data = try? Data(contentsOf: sidecar),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let chunkId = json["chunkId"] as? String,
              WatchChunkFormat.isSafeChunkId(chunkId) else { return nil }
        func int64(_ key: String) -> Int64? {
            if let n = json[key] as? NSNumber { return n.int64Value }
            if let s = json[key] as? String { return Int64(s) }
            return nil
        }
        let started = int64("startedAtMs").flatMap { $0 > 0 ? $0 : nil } ?? fallbackStartMs
        return WatchStoredChunk(
            chunkId: chunkId,
            startedAtMs: started,
            durationMs: int64("durationMs") ?? 0,
            sampleRate: Int(int64("sampleRate") ?? 16000),
            channels: Int(int64("channels") ?? 1),
            audioURL: directory.appendingPathComponent("\(chunkId).wav"),
            sidecarURL: sidecar
        )
    }
}

enum WatchChunkFormatError: Error, Equatable {
    case notWav
    case unsupported(String)
    case noAudio
}

/// WAV → offline-sync `.bin` conversion, mirroring the device WAL format the backend parses:
/// a sequence of `[uint32 LE length][payload]` frames, 320 PCM16 samples (640 bytes) each.
enum WatchChunkFormat {
    static let frameSamples = 320

    static func isSafeChunkId(_ chunkId: String) -> Bool {
        !chunkId.isEmpty && chunkId.count < 128
            && chunkId.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" || $0 == "-" }
    }

    /// `audio_<device>_<codec>_<rate>_<channels>_fs<frameSamples>_<startSeconds>.bin`; the backend
    /// maps the `applewatch` device token to the `apple_watch` conversation source.
    static func uploadFileName(startedAtMs: Int64, sampleRate: Int, channels: Int) -> String {
        "audio_applewatch_pcm16_\(sampleRate)_\(channels)_fs\(frameSamples)_\(startedAtMs / 1000).bin"
    }

    struct Wav: Equatable {
        let pcm: Data
        let sampleRate: Int
        let channels: Int
    }

    static func parseWav(_ data: Data) throws -> Wav {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { throw WatchChunkFormatError.notWav }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var offset = 12
        var sampleRate = 0
        var channels = 0
        var sawFormat = false
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                guard size >= 16, body + 16 <= bytes.count else { throw WatchChunkFormatError.notWav }
                let format = u16(body)
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                let bits = u16(body + 14)
                guard format == 1, bits == 16 else {
                    throw WatchChunkFormatError.unsupported("format=\(format) bits=\(bits)")
                }
                guard channels >= 1, sampleRate > 0 else { throw WatchChunkFormatError.unsupported("channels=\(channels) rate=\(sampleRate)") }
                sawFormat = true
            } else if id == "data" {
                guard sawFormat else { throw WatchChunkFormatError.notWav }
                // Recorders that crash mid-write can leave a stale size; clamp to what exists.
                let end = min(bytes.count, body + size)
                let frameBytes = 2 * channels
                let usable = (end - body) / frameBytes * frameBytes
                guard usable > 0 else { throw WatchChunkFormatError.noAudio }
                return Wav(pcm: Data(bytes[body..<body + usable]), sampleRate: sampleRate, channels: channels)
            }
            offset = body + size + (size & 1)
        }
        throw sawFormat ? WatchChunkFormatError.noAudio : WatchChunkFormatError.notWav
    }

    static func syncBin(pcm: Data, channels: Int) -> Data {
        let frameBytes = frameSamples * 2 * max(1, channels)
        var out = Data(capacity: pcm.count + (pcm.count / frameBytes + 1) * 4)
        var index = pcm.startIndex
        while index < pcm.endIndex {
            let end = min(pcm.endIndex, index + frameBytes)
            var length = UInt32(end - index).littleEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(pcm[index..<end])
            index = end
        }
        return out
    }

    /// RFC 7578 body with one `files` part per entry, matching Dart's `MultipartFile.fromPath('files', ...)`.
    static func multipartBody(boundary: String, files: [(filename: String, data: Data)]) -> Data {
        var body = Data()
        for file in files {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(file.filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(file.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

/// Classified `POST /v2/sync-local-files` response (same mapping as Dart `uploadLocalFilesV2`).
enum WatchUploadOutcome: Equatable {
    case queued(jobId: String)
    case completed
    case incomplete(failedSegments: Int)
    case rateLimited(retryAfter: TimeInterval)
    case unauthorized
    case rejected(String)
    case recoveryWindowExceeded
    case transient(String)
}

/// Classified `GET /v2/sync-local-files/{jobId}` response.
enum WatchJobOutcome: Equatable {
    case completed
    case failed(String)
    case processing
    case notFound
    case transient(String)
}

enum WatchSyncClassifier {
    private static func json(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func header(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        for (key, value) in headers {
            if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame {
                return (value as? String)?.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func retryAfter(_ headers: [AnyHashable: Any], fallback: TimeInterval = 60) -> TimeInterval {
        guard let raw = header(headers, "Retry-After"), let seconds = Double(raw), seconds >= 0 else { return fallback }
        return min(max(seconds, 1), 3600)
    }

    static func classifyUpload(statusCode: Int?, headers: [AnyHashable: Any], body: Data) -> WatchUploadOutcome {
        guard let status = statusCode else { return .transient("network") }
        switch status {
        case 200:
            guard let object = json(body) else { return .transient("unparseable 200") }
            let failed = (object["failed_segments"] as? NSNumber)?.intValue ?? 0
            return failed > 0 ? .incomplete(failedSegments: failed) : .completed
        case 202:
            guard let jobId = json(body)?["job_id"] as? String, !jobId.isEmpty else { return .transient("no job id") }
            return .queued(jobId: jobId)
        case 400:
            return .rejected("audio could not be processed")
        case 401:
            return .unauthorized
        case 413:
            return .rejected("audio too large")
        case 422 where (json(body)?["code"] as? String) == "backfill_lookback_exceeded":
            return .recoveryWindowExceeded
        case 429:
            return .rateLimited(retryAfter: retryAfter(headers))
        case 503 where header(headers, "x-omi-rate-limit-reason")?.lowercased() == "backfill_capacity":
            return .rateLimited(retryAfter: retryAfter(headers))
        default:
            return .transient("http \(status)")
        }
    }

    static func classifyJob(statusCode: Int?, body: Data) -> WatchJobOutcome {
        guard let status = statusCode else { return .transient("network") }
        switch status {
        case 200:
            guard let object = json(body), let state = object["status"] as? String else { return .transient("unparseable job") }
            switch state {
            case "completed": return .completed
            case "failed", "partial_failure":
                return .failed((object["error"] as? String) ?? state)
            default: return .processing
            }
        case 403, 404:
            return .notFound
        default:
            return .transient("http \(status)")
        }
    }
}

/// Everything the native sync persists. One file, rewritten atomically after each change.
struct WatchSyncState: Codable, Equatable {
    enum Phase: String, Codable { case uploading, processing }

    struct Batch: Codable, Equatable {
        var id: String
        var chunkIds: [String]
        var phase: Phase
        var jobId: String?
        var taskIdentifier: Int?
        var createdAt: Date
        var nextPollAt: Date?
        var acceptedAt: Date?
    }

    var batches: [Batch] = []
    /// Definitive failures per chunk id.
    var failures: [String: Int] = [:]
    /// Chunk ids confirmed complete on the server (or quarantined); the dedupe ledger.
    var doneIds: [String] = []
    /// Done ids whose ack has not yet been handed to WatchConnectivity.
    var pendingAcks: [String] = []
    var transientStreak: Int = 0
    var nextUploadAt: Date?
    var lastError: String?
}

/// Pure state transitions, ported from the former Dart `WatchChunkSyncQueue`.
struct WatchSyncPlanner {
    var maxBatchChunks = 10
    var maxDefinitiveFailures = 12
    var maxDoneIds = 3000

    struct Effects: Equatable {
        /// Ids to ack to the watch and delete locally (upload confirmed).
        var completed: [String] = []
        /// Ids to move to the failed folder and ack (watch copy is released).
        var quarantined: [String] = []
        /// Batch ids whose temp multipart file can go.
        var finishedBatches: [String] = []
    }

    static func backoff(_ attempt: Int) -> TimeInterval {
        let n = max(1, attempt)
        return min(1800, 30 * pow(2, Double(min(n - 1, 10))))
    }

    func inFlightIds(_ state: WatchSyncState) -> Set<String> {
        Set(state.batches.flatMap { $0.chunkIds })
    }

    /// Oldest first, up to `maxBatchChunks`. A chunk that already failed definitively goes
    /// alone so one bad file cannot keep failing a whole batch.
    func nextBatch(stored: [WatchStoredChunk], state: WatchSyncState, now: Date) -> [WatchStoredChunk] {
        if let next = state.nextUploadAt, next > now { return [] }
        let done = Set(state.doneIds)
        let busy = inFlightIds(state)
        let pending = stored
            .filter { !done.contains($0.chunkId) && !busy.contains($0.chunkId) }
            .sorted { ($0.startedAtMs, $0.chunkId) < ($1.startedAtMs, $1.chunkId) }
        guard let first = pending.first else { return [] }
        if (state.failures[first.chunkId] ?? 0) > 0 { return [first] }
        var batch: [WatchStoredChunk] = []
        for chunk in pending {
            if batch.count >= maxBatchChunks || (state.failures[chunk.chunkId] ?? 0) > 0 { break }
            batch.append(chunk)
        }
        return batch
    }

    /// Drop state that refers to files no longer on disk; surface duplicates of done chunks
    /// (a re-delivery after a lost ack) so the caller re-acks and deletes them.
    func reconcile(storedIds: Set<String>, state: inout WatchSyncState) -> Effects {
        var effects = Effects()
        let done = Set(state.doneIds)
        effects.completed = storedIds.filter { done.contains($0) }.sorted()
        let queuedAcks = Set(state.pendingAcks)
        state.pendingAcks.append(contentsOf: effects.completed.filter { !queuedAcks.contains($0) })
        for batch in state.batches where batch.phase == .uploading && !batch.chunkIds.contains(where: { storedIds.contains($0) }) {
            effects.finishedBatches.append(batch.id)
        }
        state.batches.removeAll { $0.phase == .uploading && !$0.chunkIds.contains(where: { storedIds.contains($0) }) }
        state.failures = state.failures.filter { storedIds.contains($0.key) }
        return effects
    }

    mutating func markDone(_ ids: [String], state: inout WatchSyncState) {
        let existing = Set(state.doneIds)
        for id in ids where !existing.contains(id) { state.doneIds.append(id) }
        if state.doneIds.count > maxDoneIds { state.doneIds.removeFirst(state.doneIds.count - maxDoneIds) }
        let pending = Set(state.pendingAcks)
        for id in ids where !pending.contains(id) { state.pendingAcks.append(id) }
        if state.pendingAcks.count > maxDoneIds { state.pendingAcks.removeFirst(state.pendingAcks.count - maxDoneIds) }
        for id in ids { state.failures.removeValue(forKey: id) }
    }

    private mutating func definitiveFailure(_ batch: WatchSyncState.Batch, reason: String, state: inout WatchSyncState, now: Date, effects: inout Effects) {
        state.lastError = reason
        guard let first = batch.chunkIds.first else { return }
        if batch.chunkIds.count > 1 {
            // Isolate: retry the oldest chunk alone next; the rest follow in later batches.
            state.failures[first, default: 0] += 1
            state.nextUploadAt = now.addingTimeInterval(Self.backoff(1))
            return
        }
        let count = (state.failures[first] ?? 0) + 1
        if count >= maxDefinitiveFailures {
            effects.quarantined.append(first)
            markDone([first], state: &state)
        } else {
            state.failures[first] = count
            state.nextUploadAt = now.addingTimeInterval(Self.backoff(count))
        }
    }

    private func remove(_ batchId: String, from state: inout WatchSyncState) -> WatchSyncState.Batch? {
        guard let index = state.batches.firstIndex(where: { $0.id == batchId }) else { return nil }
        return state.batches.remove(at: index)
    }

    mutating func applyUpload(_ outcome: WatchUploadOutcome, batchId: String, state: inout WatchSyncState, now: Date) -> Effects {
        var effects = Effects()
        guard let index = state.batches.firstIndex(where: { $0.id == batchId }) else { return effects }
        if case let .queued(jobId) = outcome {
            state.batches[index].phase = .processing
            state.batches[index].jobId = jobId
            state.batches[index].taskIdentifier = nil
            state.batches[index].acceptedAt = now
            state.batches[index].nextPollAt = now.addingTimeInterval(3)
            state.transientStreak = 0
            state.lastError = nil
            effects.finishedBatches.append(batchId)
            return effects
        }
        guard let batch = remove(batchId, from: &state) else { return effects }
        effects.finishedBatches.append(batchId)
        switch outcome {
        case .queued:
            break
        case .completed:
            state.transientStreak = 0
            state.lastError = nil
            effects.completed = batch.chunkIds
            markDone(batch.chunkIds, state: &state)
        case let .incomplete(failed):
            definitiveFailure(batch, reason: "\(failed) segment(s) failed", state: &state, now: now, effects: &effects)
        case let .rejected(reason):
            definitiveFailure(batch, reason: reason, state: &state, now: now, effects: &effects)
        case .recoveryWindowExceeded:
            if batch.chunkIds.count == 1 {
                state.lastError = "older than the server recovery window"
                effects.quarantined = batch.chunkIds
                markDone(batch.chunkIds, state: &state)
            } else if let first = batch.chunkIds.first {
                state.failures[first, default: 0] += 1
            }
        case let .rateLimited(retryAfter):
            state.lastError = "rate limited"
            state.nextUploadAt = now.addingTimeInterval(retryAfter)
        case .unauthorized:
            state.lastError = "unauthorized"
            state.nextUploadAt = now.addingTimeInterval(60)
        case let .transient(reason):
            state.lastError = reason
            state.transientStreak += 1
            state.nextUploadAt = now.addingTimeInterval(Self.backoff(state.transientStreak))
        }
        return effects
    }

    mutating func applyJob(_ outcome: WatchJobOutcome, batchId: String, state: inout WatchSyncState, now: Date) -> Effects {
        var effects = Effects()
        guard let index = state.batches.firstIndex(where: { $0.id == batchId }) else { return effects }
        switch outcome {
        case .processing:
            let age = now.timeIntervalSince(state.batches[index].acceptedAt ?? now)
            state.batches[index].nextPollAt = now.addingTimeInterval(age < 120 ? 3 : 30)
        case let .transient(reason):
            state.lastError = reason
            state.batches[index].nextPollAt = now.addingTimeInterval(30)
        case .completed:
            let batch = state.batches.remove(at: index)
            state.lastError = nil
            effects.completed = batch.chunkIds
            markDone(batch.chunkIds, state: &state)
        case .notFound:
            // Job expired or unknown: upload again (the backend dedupes segments).
            state.batches.remove(at: index)
            state.nextUploadAt = now.addingTimeInterval(5)
        case let .failed(reason):
            let batch = state.batches.remove(at: index)
            definitiveFailure(batch, reason: reason, state: &state, now: now, effects: &effects)
        }
        return effects
    }

    /// A chunk whose audio cannot be read is quarantined at once; retrying cannot help.
    mutating func unreadable(_ chunkId: String, state: inout WatchSyncState) -> Effects {
        var effects = Effects()
        effects.quarantined = [chunkId]
        state.lastError = "unreadable audio \(chunkId)"
        markDone([chunkId], state: &state)
        return effects
    }

    /// Batches stuck in `uploading` whose URLSession task no longer exists (e.g. the user
    /// force-quit the app, which cancels background transfers) go back to pending.
    func dropOrphanedUploads(liveTaskBatchIds: Set<String>, state: inout WatchSyncState) -> [String] {
        let orphans = state.batches.filter { $0.phase == .uploading && !liveTaskBatchIds.contains($0.id) }.map { $0.id }
        state.batches.removeAll { orphans.contains($0.id) }
        return orphans
    }

    /// One-time import of the Dart ledger that owned uploads before 1.0.544.
    mutating func importLegacy(doneIds: [String], jobs: [String: [String]], state: inout WatchSyncState, now: Date) {
        let known = Set(state.doneIds)
        let fresh = doneIds.filter { WatchChunkFormat.isSafeChunkId($0) && !known.contains($0) }
        state.doneIds.append(contentsOf: fresh)
        if state.doneIds.count > maxDoneIds { state.doneIds.removeFirst(state.doneIds.count - maxDoneIds) }
        let busy = inFlightIds(state).union(state.doneIds)
        for (jobId, ids) in jobs.sorted(by: { $0.key < $1.key }) {
            let chunkIds = ids.filter { WatchChunkFormat.isSafeChunkId($0) && !busy.contains($0) }
            guard !jobId.isEmpty, !chunkIds.isEmpty else { continue }
            state.batches.append(.init(id: "legacy-\(jobId)", chunkIds: chunkIds, phase: .processing, jobId: jobId,
                                       taskIdentifier: nil, createdAt: now, nextPollAt: now, acceptedAt: now))
        }
    }

    func nextWakeDate(_ state: WatchSyncState, hasPendingChunks: Bool) -> Date? {
        var dates = state.batches.compactMap { $0.phase == .processing ? $0.nextPollAt : nil }
        if hasPendingChunks { dates.append(state.nextUploadAt ?? Date.distantPast) }
        return dates.min()
    }
}

enum WatchSyncStateStore {
    static func load(_ url: URL) -> WatchSyncState {
        guard let data = try? Data(contentsOf: url) else { return WatchSyncState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode(WatchSyncState.self, from: data)) ?? WatchSyncState()
    }

    static func save(_ state: WatchSyncState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
