# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Compiles the Foundation-only core of the native watch-chunk uploader
# (Runner/WatchChunkSyncCore.swift) with plain swiftc and runs behavioural checks:
# WAL framing, multipart body, response classification, batch planning, failure
# isolation/quarantine, dedupe re-ack, orphaned uploads, legacy import, state round-trip.
class WatchChunkSyncCoreTest < Minitest::Test
  IOS_ROOT = File.expand_path('..', __dir__)
  CORE_SOURCE = File.join(IOS_ROOT, 'Runner', 'WatchChunkSyncCore.swift')
  GLUE_SOURCE = File.join(IOS_ROOT, 'Runner', 'WatchChunkSync.swift')
  APP_DELEGATE = File.join(IOS_ROOT, 'Runner', 'AppDelegate.swift')
  INFO_PLIST = File.join(IOS_ROOT, 'Runner', 'Info.plist')
  PROJECT_FILE = File.join(IOS_ROOT, 'Runner.xcodeproj', 'project.pbxproj')

  HARNESS = <<~'SWIFT'
    import Foundation

    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        if !condition() { failures.append("line \(line): \(message)") }
    }

    func wav(samples: Int, sampleRate: Int = 16000, channels: Int = 1, bits: Int = 16, format: Int = 1, extraChunk: Bool = false) -> Data {
        var d = Data()
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let dataBytes = samples * channels * 2
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(format); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        if extraChunk { d.append("LIST".data(using: .ascii)!); u32(3); d.append(contentsOf: [1, 2, 3, 0]) }
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        for i in 0..<(samples * channels) { u16(i & 0x7fff) }
        return d
    }

    func chunk(_ id: String, _ start: Int64) -> WatchStoredChunk {
        WatchStoredChunk(chunkId: id, startedAtMs: start, durationMs: 30000, sampleRate: 16000, channels: 1,
                         audioURL: URL(fileURLWithPath: "/tmp/\(id).wav"), sidecarURL: URL(fileURLWithPath: "/tmp/\(id).json"))
    }

    func batch(_ id: String, _ ids: [String], _ phase: WatchSyncState.Phase = .uploading, job: String? = nil) -> WatchSyncState.Batch {
        .init(id: id, chunkIds: ids, phase: phase, jobId: job, taskIdentifier: nil, createdAt: Date(timeIntervalSince1970: 0),
              nextPollAt: nil, acceptedAt: nil)
    }

    @main
    struct Main {
        static func main() throws {
            let now = Date(timeIntervalSince1970: 1_800_000_000)

            // --- Format ---
            check(WatchChunkFormat.uploadFileName(startedAtMs: 1_759_300_000_123, sampleRate: 16000, channels: 1)
                  == "audio_applewatch_pcm16_16000_1_fs320_1759300000.bin", "upload filename")
            check(WatchChunkFormat.isSafeChunkId("A1_b-2"), "safe id")
            check(!WatchChunkFormat.isSafeChunkId("../x"), "path traversal id rejected")
            check(!WatchChunkFormat.isSafeChunkId(""), "empty id rejected")

            let parsed = try WatchChunkFormat.parseWav(wav(samples: 700, extraChunk: true))
            check(parsed.sampleRate == 16000 && parsed.channels == 1 && parsed.pcm.count == 1400, "wav parse with extra chunk")
            let bin = WatchChunkFormat.syncBin(pcm: parsed.pcm, channels: 1)
            // 700 samples -> frames of 640, 640, 120 bytes, each with a 4-byte LE length.
            check(bin.count == 1400 + 12, "bin size \(bin.count)")
            check(Array(bin[0..<4]) == [0x80, 0x02, 0, 0], "first frame length 640 LE")
            check(Array(bin[644..<648]) == [0x80, 0x02, 0, 0], "second frame length 640 LE")
            check(Array(bin[1288..<1292]) == [120, 0, 0, 0], "tail frame length 120 LE")
            check(bin[4..<644] == parsed.pcm[0..<640], "frame payload is raw pcm")

            var truncated = wav(samples: 100)
            truncated.removeLast(51) // stale data size + odd byte count
            check((try? WatchChunkFormat.parseWav(truncated))?.pcm.count == 148, "truncated wav clamps to whole samples")
            check((try? WatchChunkFormat.parseWav(Data("nope".utf8))) == nil, "non-wav rejected")
            do { _ = try WatchChunkFormat.parseWav(wav(samples: 10, bits: 8)); check(false, "8-bit accepted") }
            catch let e as WatchChunkFormatError { if case .unsupported = e {} else { check(false, "8-bit error kind \(e)") } }
            do { _ = try WatchChunkFormat.parseWav(wav(samples: 0)); check(false, "empty accepted") }
            catch let e as WatchChunkFormatError { check(e == .noAudio, "empty wav -> noAudio") }

            let body = String(decoding: WatchChunkFormat.multipartBody(boundary: "B", files: [("a.bin", Data("xy".utf8)), ("b.bin", Data())]), as: UTF8.self)
            check(body == "--B\r\nContent-Disposition: form-data; name=\"files\"; filename=\"a.bin\"\r\nContent-Type: application/octet-stream\r\n\r\nxy\r\n"
                  + "--B\r\nContent-Disposition: form-data; name=\"files\"; filename=\"b.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--B--\r\n",
                  "multipart body:\n\(body)")

            // --- Classifiers ---
            let j = { (s: String) in Data(s.utf8) }
            check(WatchSyncClassifier.classifyUpload(statusCode: 202, headers: [:], body: j(#"{"job_id":"J"}"#)) == .queued(jobId: "J"), "202")
            check(WatchSyncClassifier.classifyUpload(statusCode: 202, headers: [:], body: j("{}")) == .transient("no job id"), "202 w/o job")
            check(WatchSyncClassifier.classifyUpload(statusCode: 200, headers: [:], body: j(#"{"failed_segments":0}"#)) == .completed, "200 ok")
            check(WatchSyncClassifier.classifyUpload(statusCode: 200, headers: [:], body: j(#"{"failed_segments":2}"#)) == .incomplete(failedSegments: 2), "200 partial")
            check(WatchSyncClassifier.classifyUpload(statusCode: 400, headers: [:], body: Data()) == .rejected("audio could not be processed"), "400")
            check(WatchSyncClassifier.classifyUpload(statusCode: 413, headers: [:], body: Data()) == .rejected("audio too large"), "413")
            check(WatchSyncClassifier.classifyUpload(statusCode: 401, headers: [:], body: Data()) == .unauthorized, "401")
            check(WatchSyncClassifier.classifyUpload(statusCode: 422, headers: [:], body: j(#"{"code":"backfill_lookback_exceeded","detail":"x"}"#)) == .recoveryWindowExceeded, "422 lookback")
            check(WatchSyncClassifier.classifyUpload(statusCode: 422, headers: [:], body: j("{}")) == .transient("http 422"), "other 422")
            check(WatchSyncClassifier.classifyUpload(statusCode: 429, headers: ["Retry-After": "120"], body: Data()) == .rateLimited(retryAfter: 120), "429")
            check(WatchSyncClassifier.classifyUpload(statusCode: 503, headers: ["X-Omi-Rate-Limit-Reason": "backfill_capacity"], body: Data()) == .rateLimited(retryAfter: 60), "503 capacity")
            check(WatchSyncClassifier.classifyUpload(statusCode: 503, headers: [:], body: Data()) == .transient("http 503"), "503")
            check(WatchSyncClassifier.classifyUpload(statusCode: nil, headers: [:], body: Data()) == .transient("network"), "network")
            check(WatchSyncClassifier.classifyJob(statusCode: 200, body: j(#"{"status":"completed"}"#)) == .completed, "job completed")
            check(WatchSyncClassifier.classifyJob(statusCode: 200, body: j(#"{"status":"processing"}"#)) == .processing, "job processing")
            check(WatchSyncClassifier.classifyJob(statusCode: 200, body: j(#"{"status":"partial_failure"}"#)) == .failed("partial_failure"), "job partial")
            check(WatchSyncClassifier.classifyJob(statusCode: 200, body: j(#"{"status":"failed","error":"boom"}"#)) == .failed("boom"), "job failed")
            check(WatchSyncClassifier.classifyJob(statusCode: 404, body: Data()) == .notFound, "job 404")
            check(WatchSyncClassifier.classifyJob(statusCode: 403, body: Data()) == .notFound, "job 403")
            check(WatchSyncClassifier.classifyJob(statusCode: 500, body: Data()) == .transient("http 500"), "job 500")

            // --- Planner: batching ---
            var planner = WatchSyncPlanner()
            var state = WatchSyncState()
            let stored = (0..<14).map { chunk("c\($0)", Int64(1000 * (14 - $0))) } // reverse order on disk
            var next = planner.nextBatch(stored: stored, state: state, now: now)
            check(next.count == 10 && next.first?.chunkId == "c13" && next.last?.chunkId == "c4", "oldest-first batch of 10")
            state.batches.append(batch("b1", next.map { $0.chunkId }))
            next = planner.nextBatch(stored: stored, state: state, now: now)
            check(next.map { $0.chunkId } == ["c3", "c2", "c1", "c0"], "in-flight chunks are never batched twice")
            state.doneIds = ["c3"]
            next = planner.nextBatch(stored: stored, state: state, now: now)
            check(next.map { $0.chunkId } == ["c2", "c1", "c0"], "done chunks are never uploaded again")

            // --- Planner: upload accepted -> processing -> completed ---
            state = WatchSyncState()
            state.batches = [batch("b1", ["a", "b"])]
            var fx = planner.applyUpload(.queued(jobId: "J"), batchId: "b1", state: &state, now: now)
            check(state.batches.first?.phase == .processing && state.batches.first?.jobId == "J", "202 moves batch to processing")
            check(fx.completed.isEmpty && state.pendingAcks.isEmpty, "no ack before the job completes")
            check(fx.finishedBatches == ["b1"], "upload body released after acceptance")
            check(planner.nextBatch(stored: [chunk("a", 1), chunk("b", 2)], state: state, now: now).isEmpty, "processing chunks are not re-uploaded")
            fx = planner.applyJob(.processing, batchId: "b1", state: &state, now: now.addingTimeInterval(10))
            check(state.batches.first?.nextPollAt == now.addingTimeInterval(13), "poll again in 3s while young")
            fx = planner.applyJob(.processing, batchId: "b1", state: &state, now: now.addingTimeInterval(200))
            check(state.batches.first?.nextPollAt == now.addingTimeInterval(230), "poll every 30s when old")
            fx = planner.applyJob(.completed, batchId: "b1", state: &state, now: now)
            check(fx.completed == ["a", "b"] && state.batches.isEmpty, "job completion releases chunks")
            check(state.doneIds == ["a", "b"] && state.pendingAcks == ["a", "b"], "completed chunks queued for watch ack")

            // --- Re-delivery of a done chunk (lost ack) is re-acked and deleted, not re-uploaded ---
            state.pendingAcks = []
            fx = planner.reconcile(storedIds: ["a", "z"], state: &state)
            check(fx.completed == ["a"] && state.pendingAcks == ["a"], "duplicate of done chunk is re-acked")
            check(planner.nextBatch(stored: [chunk("a", 1), chunk("z", 2)], state: state, now: now).map { $0.chunkId } == ["z"], "only new chunk uploads")

            // --- Failure isolation and quarantine ---
            state = WatchSyncState()
            state.batches = [batch("b2", ["x", "y", "z"])]
            fx = planner.applyUpload(.rejected("bad"), batchId: "b2", state: &state, now: now)
            check(state.failures == ["x": 1] && state.batches.isEmpty, "multi-chunk failure blames the oldest chunk")
            check(state.nextUploadAt == now.addingTimeInterval(30), "backoff after failure")
            let solo = planner.nextBatch(stored: [chunk("x", 1), chunk("y", 2), chunk("z", 3)], state: state, now: now.addingTimeInterval(31))
            check(solo.map { $0.chunkId } == ["x"], "previously failing chunk goes alone")
            let behind = planner.nextBatch(stored: [chunk("w", 0), chunk("x", 1), chunk("y", 2)], state: state, now: now.addingTimeInterval(31))
            check(behind.map { $0.chunkId } == ["w"], "batch stops before a failing chunk")
            state.failures["x"] = 11
            state.batches = [batch("b3", ["x"])]
            fx = planner.applyUpload(.incomplete(failedSegments: 1), batchId: "b3", state: &state, now: now)
            check(fx.quarantined == ["x"] && state.doneIds.contains("x") && state.failures["x"] == nil, "12th definitive failure quarantines")
            state.batches = [batch("b4", ["q"], .processing, job: "J")]
            fx = planner.applyJob(.failed("partial_failure"), batchId: "b4", state: &state, now: now)
            check(state.failures["q"] == 1 && state.batches.isEmpty, "failed job counts a definitive failure")
            state.batches = [batch("b5", ["r"])]
            fx = planner.applyUpload(.recoveryWindowExceeded, batchId: "b5", state: &state, now: now)
            check(fx.quarantined == ["r"], "chunk past the recovery window is quarantined")
            fx = planner.unreadable("u", state: &state)
            check(fx.quarantined == ["u"] && state.doneIds.contains("u"), "unreadable audio quarantined immediately")

            // --- Transient / rate limit / auth / not found ---
            state = WatchSyncState()
            state.batches = [batch("t1", ["a"])]
            _ = planner.applyUpload(.transient("network"), batchId: "t1", state: &state, now: now)
            state.batches = [batch("t2", ["a"])]
            _ = planner.applyUpload(.transient("network"), batchId: "t2", state: &state, now: now)
            check(state.transientStreak == 2 && state.nextUploadAt == now.addingTimeInterval(60) && state.failures.isEmpty, "transient backoff, no failure count")
            check(planner.nextBatch(stored: [chunk("a", 1)], state: state, now: now.addingTimeInterval(59)).isEmpty, "respects backoff")
            check(planner.nextBatch(stored: [chunk("a", 1)], state: state, now: now.addingTimeInterval(61)).count == 1, "retries after backoff")
            state.batches = [batch("t3", ["a"])]
            _ = planner.applyUpload(.rateLimited(retryAfter: 90), batchId: "t3", state: &state, now: now)
            check(state.nextUploadAt == now.addingTimeInterval(90), "Retry-After honoured")
            state.batches = [batch("t4", ["a"], .processing, job: "J")]
            _ = planner.applyJob(.notFound, batchId: "t4", state: &state, now: now)
            check(state.batches.isEmpty && state.nextUploadAt == now.addingTimeInterval(5), "unknown job falls back to re-upload")
            state.batches = [batch("t5", ["a"], .processing, job: "J")]
            _ = planner.applyJob(.transient("http 502"), batchId: "t5", state: &state, now: now)
            check(state.batches.count == 1 && state.batches[0].nextPollAt == now.addingTimeInterval(30), "transient poll keeps the job")
            check(WatchSyncPlanner.backoff(1) == 30 && WatchSyncPlanner.backoff(3) == 120 && WatchSyncPlanner.backoff(20) == 1800, "backoff curve")

            // --- Orphaned uploads (task gone after force-quit) and missing files ---
            state = WatchSyncState()
            state.batches = [batch("live", ["a"]), batch("dead", ["b"]), batch("job", ["c"], .processing, job: "J")]
            let orphans = planner.dropOrphanedUploads(liveTaskBatchIds: ["live"], state: &state)
            check(orphans == ["dead"] && state.batches.map { $0.id } == ["live", "job"], "orphaned upload requeued, jobs kept")
            state.failures = ["gone": 2, "a": 1]
            fx = planner.reconcile(storedIds: ["c"], state: &state)
            check(state.batches.map { $0.id } == ["job"] && fx.finishedBatches == ["live"], "upload batch with no files dropped")
            check(state.failures.isEmpty, "failure counts for deleted chunks dropped")

            // --- Legacy Dart ledger import ---
            state = WatchSyncState()
            planner.importLegacy(doneIds: ["d1", "../bad"], jobs: ["J1": ["p1", "p2"], "J2": ["d1"]], state: &state, now: now)
            check(state.doneIds == ["d1"], "legacy done ids imported (unsafe dropped)")
            check(state.batches.count == 1 && state.batches[0].jobId == "J1" && state.batches[0].chunkIds == ["p1", "p2"]
                  && state.batches[0].phase == .processing, "legacy in-flight job imported for confirmation")
            planner.importLegacy(doneIds: ["d1"], jobs: ["J1": ["p1", "p2"]], state: &state, now: now)
            check(state.doneIds == ["d1"] && state.batches.count == 1, "legacy import is idempotent")

            // --- Done ledger cap ---
            var capped = WatchSyncPlanner(); capped.maxDoneIds = 3
            var small = WatchSyncState()
            capped.markDone(["1", "2", "3", "4"], state: &small)
            check(small.doneIds == ["2", "3", "4"] && small.pendingAcks == ["2", "3", "4"], "done ledger capped oldest-first")

            // --- Wake planning ---
            state = WatchSyncState()
            state.batches = [batch("p", ["a"], .processing, job: "J")]
            state.batches[0].nextPollAt = now.addingTimeInterval(40)
            state.nextUploadAt = now.addingTimeInterval(100)
            check(planner.nextWakeDate(state, hasPendingChunks: true) == now.addingTimeInterval(40), "wake for next poll")
            check(planner.nextWakeDate(WatchSyncState(), hasPendingChunks: false) == nil, "nothing to do")

            // --- State round-trip and sidecar parsing ---
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            state.doneIds = ["a"]; state.failures = ["b": 2]; state.lastError = "x"
            try WatchSyncStateStore.save(state, to: dir.appendingPathComponent("s/state.json"))
            check(WatchSyncStateStore.load(dir.appendingPathComponent("s/state.json")) == state, "state round-trip")
            check(WatchSyncStateStore.load(dir.appendingPathComponent("missing.json")) == WatchSyncState(), "missing state -> empty")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sidecar = dir.appendingPathComponent("k1.json")
            try Data(#"{"kind":"omiWatchChunk","chunkId":"k1","startedAtMs":1759300000123,"durationMs":30000,"sampleRate":16000,"channels":1}"#.utf8).write(to: sidecar)
            let meta = WatchStoredChunk.from(sidecar: sidecar, directory: dir, fallbackStartMs: 5)
            check(meta?.chunkId == "k1" && meta?.startedAtMs == 1_759_300_000_123 && meta?.audioURL.lastPathComponent == "k1.wav", "sidecar parse")
            try Data(#"{"chunkId":"k2"}"#.utf8).write(to: dir.appendingPathComponent("k2.json"))
            check(WatchStoredChunk.from(sidecar: dir.appendingPathComponent("k2.json"), directory: dir, fallbackStartMs: 5)?.startedAtMs == 5, "sidecar fallback start")
            try Data(#"{"chunkId":"../evil"}"#.utf8).write(to: dir.appendingPathComponent("k3.json"))
            check(WatchStoredChunk.from(sidecar: dir.appendingPathComponent("k3.json"), directory: dir, fallbackStartMs: 5) == nil, "unsafe sidecar id rejected")

            if failures.isEmpty {
                print("watch chunk sync core: all checks passed")
            } else {
                failures.forEach { print("FAIL \($0)") }
                exit(1)
            }
        }
    }
  SWIFT

  def test_core_behaviour
    Dir.mktmpdir('watch-chunk-sync-core') do |directory|
      harness = File.join(directory, 'main.swift')
      binary = File.join(directory, 'watch-chunk-sync-core-test')
      File.write(harness, HARNESS)
      stdout, stderr, status = Open3.capture3('swiftc', '-parse-as-library', CORE_SOURCE, harness, '-o', binary)
      assert status.success?, "swiftc failed:\n#{stdout}\n#{stderr}"
      stdout, stderr, status = Open3.capture3(binary)
      assert status.success?, "core checks failed:\n#{stdout}\n#{stderr}"
    end
  end

  def test_background_identifiers_are_permitted_and_registered
    plist = File.binread(INFO_PLIST)
    glue = File.binread(GLUE_SOURCE)
    %w[com.omi.watchchunks.refresh com.omi.watchchunks.processing].each do |identifier|
      assert_includes plist, "<string>#{identifier}</string>", "#{identifier} must be in BGTaskSchedulerPermittedIdentifiers"
      assert_includes glue, %("#{identifier}")
    end
    %w[fetch processing].each { |mode| assert_includes plist, "<string>#{mode}</string>" }
  end

  def test_app_delegate_wires_launch_session_events_and_activation
    delegate = File.binread(APP_DELEGATE)
    launch = delegate[/didFinishLaunchingWithOptions.*?return true/m]
    refute_nil launch
    assert_operator launch.index('WatchChunkSync.shared.start()'), :<, launch.index('return true'),
                    'BG tasks must be registered before didFinishLaunching returns (including the AppLinks early return)'
    assert_match(/handleEventsForBackgroundURLSession.*WatchChunkSync\.shared\.handleBackgroundSessionEvents/m, delegate)
    assert_match(/activationDidCompleteWith[^}]*WatchChunkSync\.shared\.kick/m, delegate)
  end

  def test_new_sources_are_compiled_into_the_runner
    project = File.binread(PROJECT_FILE)
    %w[WatchChunkSyncCore.swift WatchChunkSync.swift].each do |file|
      assert_equal 1, project.scan(%r{/\* #{Regexp.escape(file)} \*/ = \{isa = PBXFileReference}).size
      assert_equal 2, project.scan(%r{/\* #{Regexp.escape(file)} in Sources \*/ = \{isa = PBXBuildFile}).size
    end
  end
end
