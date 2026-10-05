import Foundation
import UIKit
import Flutter
import WatchConnectivity
import BackgroundTasks
import FirebaseCore
import FirebaseAuth

/// Phone-side landing zone for Apple Watch store-and-forward audio chunks.
///
/// The watch queues each finished chunk with `WCSession.transferFile`; iOS delivers it here
/// even when the phone app is suspended or not running (WatchConnectivity launches it in the
/// background). The file must be moved before the delegate call returns, so this class
/// persists it (audio + JSON sidecar, the sidecar being the commit marker) and immediately
/// hands it to `WatchChunkSync`, which uploads natively with a background URLSession.
final class WatchChunkInbox {
    static let shared = WatchChunkInbox()
    static let channelName = "com.omi.watch/chunks"

    private var channel: FlutterMethodChannel?
    private let fileManager = FileManager.default

    var directory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("watch_chunks", isDirectory: true)
    }

    var failedDirectory: URL { directory.appendingPathComponent("failed", isDirectory: true) }

    func attach(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterMethodNotImplemented)
                return
            }
            let arguments = call.arguments as? [String: Any]
            switch call.method {
            case "getInboxPath":
                try? self.fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
                result(self.directory.path)
            case "configureSync":
                WatchChunkSync.shared.configure(arguments ?? [:]) { result($0) }
            case "kick":
                WatchChunkSync.shared.kick(reason: "dart")
                result(true)
            case "syncStatus":
                WatchChunkSync.shared.status { result($0) }
            case "configureWatch":
                var payload: [String: Any] = ["method": "chunkConfig"]
                if let seconds = arguments?["chunkSeconds"] as? Double { payload["chunkSeconds"] = seconds }
                if let maxBytes = arguments?["maxStorageBytes"] as? Int { payload["maxStorageBytes"] = Int64(maxBytes) }
                result(self.send(payload))
            case "isWatchAppInstalled":
                let session = WCSession.default
                result(WCSession.isSupported() && session.activationState == .activated && session.isPaired && session.isWatchAppInstalled)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        self.channel = channel
    }

    /// Called from `session(_:didReceive:)`. Must finish synchronously: WatchConnectivity
    /// deletes `file.fileURL` as soon as the delegate method returns.
    func receive(_ file: WCSessionFile) {
        guard let metadata = file.metadata,
              metadata["kind"] as? String == "omiWatchChunk",
              let chunkId = metadata["chunkId"] as? String,
              WatchChunkFormat.isSafeChunkId(chunkId) else {
            NSLog("[WatchChunks] ignoring unexpected file transfer \(file.fileURL.lastPathComponent)")
            return
        }
        let audio = directory.appendingPathComponent("\(chunkId).wav")
        let sidecar = directory.appendingPathComponent("\(chunkId).json")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: audio.path) {
                // Re-delivery of a chunk we already hold (no ack reached the watch yet).
                NSLog("[WatchChunks] duplicate delivery of \(chunkId); keeping existing copy")
            } else {
                try fileManager.moveItem(at: file.fileURL, to: audio)
            }
            if !fileManager.fileExists(atPath: sidecar.path) {
                var record: [String: Any] = [:]
                for (key, value) in metadata where JSONSerialization.isValidJSONObject([key: value]) {
                    record[key] = value
                }
                record["receivedAtMs"] = Int64(Date().timeIntervalSince1970 * 1000)
                let data = try JSONSerialization.data(withJSONObject: record, options: [])
                try data.write(to: sidecar, options: .atomic)
            }
            NSLog("[WatchChunks] stored \(chunkId)")
        } catch {
            NSLog("[WatchChunks] failed to persist \(chunkId): \(error.localizedDescription)")
            return
        }
        WatchChunkSync.shared.kick(reason: "chunk \(chunkId)", holdBackgroundTime: true)
    }

    /// Tell the watch these chunks are uploaded + transcribed so it can delete them.
    /// transferUserInfo is queued by the OS and survives disconnects; sendMessage is the fast path.
    @discardableResult
    func ack(chunkIds: [String]) -> Bool {
        let ids = chunkIds.filter(WatchChunkFormat.isSafeChunkId)
        guard !ids.isEmpty else { return true }
        return send(["method": "chunkAck", "chunkIds": ids])
    }

    private func send(_ payload: [String: Any]) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return false }
        session.transferUserInfo(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        return true
    }
}

/// Native, hands-off upload of watch chunks to `/v2/sync-local-files`.
///
/// - Runs without Flutter: triggered by WatchConnectivity file delivery (background launch),
///   background URLSession completion events, BGTaskScheduler refresh/processing tasks and
///   app activation. Dart only supplies configuration (`configureSync`) and optional nudges.
/// - Uploads go through a background URLSession, so the transfer itself continues while the
///   app is suspended; iOS relaunches the app in the background when it finishes.
/// - A chunk is acked to the watch (and deleted on the phone) only after the server job is
///   confirmed `completed`. State, including the done-id dedupe ledger, lives in one file.
/// - All mutable state is confined to the serial `queue` (URLSession delegate callbacks run on
///   it too), hence `@unchecked Sendable`.
final class WatchChunkSync: NSObject, @unchecked Sendable {
    static let shared = WatchChunkSync()
    static let sessionIdentifier = "com.omi.watchchunks.upload"
    static let refreshTaskIdentifier = "com.omi.watchchunks.refresh"
    static let processingTaskIdentifier = "com.omi.watchchunks.processing"
    private static let configDefaultsKey = "omi.watchChunkSync.config.v1"
    private static let maxConcurrentUploads = 3
    private static let backgroundDrainSeconds: TimeInterval = 25

    struct Config: Codable {
        var enabled: Bool
        var apiBaseUrl: String
        var headers: [String: String]
        var firebase: [String: String]
    }

    private let queue = DispatchQueue(label: "com.omi.watchchunks.sync")
    private let fileManager = FileManager.default
    private var planner = WatchSyncPlanner()
    private var state = WatchSyncState()
    private var stateLoaded = false
    private var started = false
    private var tasksRestored = false
    private var session: URLSession?
    private lazy var pollSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
    private var responseData: [Int: Data] = [:]
    private var pollsInFlight = Set<String>()
    private var uploadsStarting = 0
    private var forceTokenRefresh = false
    private var foregroundTimer: DispatchSourceTimer?
    private var backgroundEventsCompletion: (() -> Void)?

    private var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("watch_chunk_sync", isDirectory: true)
    }
    private var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    private var uploadsDirectory: URL { supportDirectory.appendingPathComponent("uploads", isDirectory: true) }

    // MARK: - Lifecycle (main thread, from didFinishLaunching)

    /// Must run before `didFinishLaunching` returns: BGTaskScheduler requires registration
    /// during launch, and recreating the background session reattaches in-flight uploads.
    func start() {
        guard !started else { return }
        started = true
        registerBackgroundTasks()

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setForegroundTimer(active: true)
            self?.kick(reason: "active")
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setForegroundTimer(active: false)
            self?.scheduleBackgroundTasks()
        }

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.queue.async {
                self.loadStateIfNeeded()
                let live = Set(tasks.compactMap { task -> String? in
                    guard task.state != .completed, task.state != .canceling else { return nil }
                    return Self.batchId(fromTaskDescription: task.taskDescription)
                })
                let orphans = self.planner.dropOrphanedUploads(liveTaskBatchIds: live, state: &self.state)
                for batchId in orphans { self.removeUploadBody(batchId) }
                if !orphans.isEmpty { NSLog("[WatchChunks] requeued \(orphans.count) upload(s) with no live task") }
                self.tasksRestored = true
                self.persist()
                self.step()
            }
        }
    }

    /// AppDelegate `handleEventsForBackgroundURLSession`.
    func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == Self.sessionIdentifier else { return false }
        queue.async { self.backgroundEventsCompletion = completionHandler }
        start()
        return true
    }

    /// Run one sync pass. With `holdBackgroundTime`, keeps the app alive for a short window
    /// (UIApplication background task) so freshly accepted jobs can be confirmed and acked.
    func kick(reason: String, holdBackgroundTime: Bool = false) {
        if holdBackgroundTime {
            DispatchQueue.main.async { self.drainWithBackgroundTime(reason: reason) }
        } else {
            queue.async { self.step() }
        }
    }

    func configure(_ arguments: [String: Any], completion: @escaping (Any?) -> Void) {
        let config = Config(
            enabled: arguments["enabled"] as? Bool ?? true,
            apiBaseUrl: arguments["apiBaseUrl"] as? String ?? "",
            headers: (arguments["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:],
            firebase: (arguments["firebase"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        )
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configDefaultsKey)
        }
        let legacyDone = arguments["legacyDoneIds"] as? [String] ?? []
        let legacyJobs = (arguments["legacyJobs"] as? [String: Any])?.compactMapValues { $0 as? [String] } ?? [:]
        let requeue = arguments["requeueQuarantined"] as? Bool ?? false
        queue.async {
            self.loadStateIfNeeded()
            if requeue { self.requeueQuarantined() }
            if !legacyDone.isEmpty || !legacyJobs.isEmpty {
                self.planner.importLegacy(doneIds: legacyDone, jobs: legacyJobs, state: &self.state, now: Date())
                self.persist()
            }
            self.step()
            let status = self.statusSnapshot()
            DispatchQueue.main.async { completion(status) }
        }
    }

    /// Gives quarantined chunks one more round per app launch (e.g. after a long backend
    /// outage). Their watch copy is already released, so the phone copy is the only one.
    private func requeueQuarantined() {
        let inbox = WatchChunkInbox.shared
        guard let names = try? fileManager.contentsOfDirectory(atPath: inbox.failedDirectory.path) else { return }
        var ids: [String] = []
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(".json".count))
            let wav = inbox.failedDirectory.appendingPathComponent("\(id).wav")
            guard WatchChunkFormat.isSafeChunkId(id), fileManager.fileExists(atPath: wav.path) else { continue }
            do {
                for ext in ["wav", "json"] {
                    let target = inbox.directory.appendingPathComponent("\(id).\(ext)")
                    try? fileManager.removeItem(at: target)
                    try fileManager.moveItem(at: inbox.failedDirectory.appendingPathComponent("\(id).\(ext)"), to: target)
                }
                ids.append(id)
            } catch {
                NSLog("[WatchChunks] could not requeue \(id): \(error.localizedDescription)")
            }
        }
        guard !ids.isEmpty else { return }
        let requeued = Set(ids)
        state.doneIds.removeAll { requeued.contains($0) }
        state.pendingAcks.removeAll { requeued.contains($0) }
        for id in ids { state.failures.removeValue(forKey: id) }
        persist()
        NSLog("[WatchChunks] re-queued \(ids.count) quarantined chunk(s)")
    }

    func status(completion: @escaping (Any?) -> Void) {
        queue.async {
            self.loadStateIfNeeded()
            let status = self.statusSnapshot()
            DispatchQueue.main.async { completion(status) }
        }
    }

    // MARK: - BGTaskScheduler

    private func registerBackgroundTasks() {
        let scheduler = BGTaskScheduler.shared
        _ = scheduler.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { [weak self] task in
            self?.runBackgroundTask(task)
        }
        _ = scheduler.register(forTaskWithIdentifier: Self.processingTaskIdentifier, using: nil) { [weak self] task in
            self?.runBackgroundTask(task)
        }
    }

    private func runBackgroundTask(_ task: BGTask) {
        var finished = false
        let finish: (Bool) -> Void = { success in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                task.setTaskCompleted(success: success)
            }
        }
        task.expirationHandler = { finish(false) }
        queue.async {
            self.step()
            self.waitUntilIdle(deadline: Date().addingTimeInterval(Self.backgroundDrainSeconds)) {
                self.scheduleBackgroundTasks()
                finish(true)
            }
        }
    }

    /// Asks iOS for another wake while work remains. iOS decides the actual timing.
    func scheduleBackgroundTasks() {
        queue.async {
            guard self.loadConfig()?.enabled == true else { return }
            self.loadStateIfNeeded()
            let pending = self.pendingChunkCount()
            guard pending > 0 || !self.state.batches.isEmpty || !self.state.pendingAcks.isEmpty else { return }
            let wake = self.planner.nextWakeDate(self.state, hasPendingChunks: pending > 0) ?? Date()
            let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
            refresh.earliestBeginDate = max(wake, Date().addingTimeInterval(15 * 60))
            let processing = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
            processing.requiresNetworkConnectivity = true
            processing.requiresExternalPower = false
            processing.earliestBeginDate = max(wake, Date().addingTimeInterval(60))
            for request in [refresh, processing] as [BGTaskRequest] {
                do { try BGTaskScheduler.shared.submit(request) } catch {
                    NSLog("[WatchChunks] could not schedule \(request.identifier): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Background time

    private func drainWithBackgroundTime(reason: String) {
        var taskId: UIBackgroundTaskIdentifier = .invalid
        var ended = false
        let end = {
            DispatchQueue.main.async {
                guard !ended else { return }
                ended = true
                if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) }
            }
        }
        taskId = UIApplication.shared.beginBackgroundTask(withName: "omi.watchChunkSync") { end() }
        queue.async {
            self.step()
            self.waitUntilIdle(deadline: Date().addingTimeInterval(Self.backgroundDrainSeconds)) {
                self.scheduleBackgroundTasks()
                end()
            }
        }
    }

    /// Re-runs `step()` every 2 s until nothing short-term is left (no token fetch or poll in
    /// flight, no job poll due within 10 s) or the deadline passes. Upload transfers themselves
    /// don't need this: the background session keeps them going while suspended.
    private func waitUntilIdle(deadline: Date, completion: @escaping () -> Void) {
        let now = Date()
        let pollSoon = state.batches.contains { $0.phase == .processing && ($0.nextPollAt ?? now) <= now.addingTimeInterval(10) }
        if now >= deadline || (pollsInFlight.isEmpty && uploadsStarting == 0 && !pollSoon) {
            completion()
            return
        }
        queue.asyncAfter(deadline: .now() + 2) {
            self.step()
            self.waitUntilIdle(deadline: deadline, completion: completion)
        }
    }

    private func setForegroundTimer(active: Bool) {
        queue.async {
            self.foregroundTimer?.cancel()
            self.foregroundTimer = nil
            guard active else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { self.step() }
            timer.resume()
            self.foregroundTimer = timer
        }
    }

    // MARK: - Sync pass (always on `queue`)

    private func step() {
        guard started, let config = loadConfig(), config.enabled, !config.apiBaseUrl.isEmpty else { return }
        loadStateIfNeeded()
        let stored = scanInbox()
        let reconcileEffects = planner.reconcile(storedIds: Set(stored.map { $0.chunkId }), state: &state)
        apply(reconcileEffects)
        flushAcks()

        let now = Date()
        for batch in state.batches where batch.phase == .processing && !pollsInFlight.contains(batch.id) {
            guard let jobId = batch.jobId, (batch.nextPollAt ?? now) <= now else { continue }
            poll(batchId: batch.id, jobId: jobId, config: config)
        }

        if tasksRestored {
            var uploading = state.batches.filter { $0.phase == .uploading }.count + uploadsStarting
            while uploading < Self.maxConcurrentUploads {
                let chunks = planner.nextBatch(stored: stored, state: state, now: Date())
                guard !chunks.isEmpty else { break }
                guard startUpload(chunks, config: config) else { break }
                uploading += 1
            }
        }
        persist()
    }

    private func scanInbox() -> [WatchStoredChunk] {
        let directory = WatchChunkInbox.shared.directory
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var chunks: [WatchStoredChunk] = []
        for name in names where name.hasSuffix(".json") {
            let sidecar = directory.appendingPathComponent(name)
            let modified = (try? fileManager.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date) ?? Date()
            guard let chunk = WatchStoredChunk.from(sidecar: sidecar, directory: directory,
                                                    fallbackStartMs: Int64(modified.timeIntervalSince1970 * 1000)),
                  fileManager.fileExists(atPath: chunk.audioURL.path) else { continue }
            chunks.append(chunk)
        }
        return chunks
    }

    private func pendingChunkCount() -> Int {
        let done = Set(state.doneIds)
        return scanInbox().filter { !done.contains($0.chunkId) }.count
    }

    /// Builds the multipart body on disk (background sessions only upload from files), records
    /// the batch, then fetches a token and starts the background upload task.
    private func startUpload(_ chunks: [WatchStoredChunk], config: Config) -> Bool {
        var parts: [(filename: String, data: Data)] = []
        var ids: [String] = []
        for chunk in chunks {
            do {
                let wav = try WatchChunkFormat.parseWav(try Data(contentsOf: chunk.audioURL))
                parts.append((WatchChunkFormat.uploadFileName(startedAtMs: chunk.startedAtMs, sampleRate: wav.sampleRate,
                                                              channels: wav.channels),
                              WatchChunkFormat.syncBin(pcm: wav.pcm, channels: wav.channels)))
                ids.append(chunk.chunkId)
            } catch let error as WatchChunkFormatError {
                NSLog("[WatchChunks] quarantining unreadable \(chunk.chunkId): \(error)")
                apply(planner.unreadable(chunk.chunkId, state: &state))
            } catch {
                NSLog("[WatchChunks] could not read \(chunk.chunkId): \(error.localizedDescription)")
                return false
            }
        }
        guard !ids.isEmpty else { return true }

        let batchId = UUID().uuidString
        let boundary = "omi-watch-\(batchId)"
        let bodyURL = uploadsDirectory.appendingPathComponent("\(batchId).body")
        do {
            try fileManager.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
            try WatchChunkFormat.multipartBody(boundary: boundary, files: parts).write(to: bodyURL, options: .atomic)
        } catch {
            NSLog("[WatchChunks] could not write upload body: \(error.localizedDescription)")
            return false
        }
        state.batches.append(.init(id: batchId, chunkIds: ids, phase: .uploading, jobId: nil, taskIdentifier: nil,
                                   createdAt: Date(), nextPollAt: nil, acceptedAt: nil))
        uploadsStarting += 1
        persist()

        withIdToken { [weak self] token in
            guard let self else { return }
            self.queue.async {
                self.uploadsStarting -= 1
                guard let index = self.state.batches.firstIndex(where: { $0.id == batchId }) else { return }
                guard let token, let session = self.session,
                      let url = Self.endpoint(config.apiBaseUrl, "v2/sync-local-files") else {
                    self.state.batches.remove(at: index)
                    self.removeUploadBody(batchId)
                    self.state.lastError = token == nil ? "no signed-in Firebase user / token" : "bad api base url"
                    self.state.nextUploadAt = Date().addingTimeInterval(60)
                    self.persist()
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                self.applyHeaders(to: &request, config: config, token: token)
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                let task = session.uploadTask(with: request, fromFile: bodyURL)
                task.taskDescription = "upload:\(batchId)"
                let size = (try? self.fileManager.attributesOfItem(atPath: bodyURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                task.countOfBytesClientExpectsToSend = size
                task.countOfBytesClientExpectsToReceive = 4096
                self.state.batches[index].taskIdentifier = task.taskIdentifier
                self.persist()
                task.resume()
                NSLog("[WatchChunks] uploading batch \(batchId) (\(ids.count) chunk(s), \(size) bytes)")
            }
        }
        return true
    }

    private func poll(batchId: String, jobId: String, config: Config) {
        guard let url = Self.endpoint(config.apiBaseUrl, "v2/sync-local-files/\(jobId)") else { return }
        pollsInFlight.insert(batchId)
        withIdToken { [weak self] token in
            guard let self else { return }
            guard let token else {
                self.queue.async {
                    self.pollsInFlight.remove(batchId)
                    self.finishPoll(.transient("no token"), batchId: batchId)
                }
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            self.applyHeaders(to: &request, config: config, token: token)
            self.pollSession.dataTask(with: request) { data, response, error in
                let status = error == nil ? (response as? HTTPURLResponse)?.statusCode : nil
                let outcome = WatchSyncClassifier.classifyJob(statusCode: status, body: data ?? Data())
                self.queue.async {
                    self.pollsInFlight.remove(batchId)
                    if status == 401 { self.forceTokenRefresh = true }
                    self.finishPoll(outcome, batchId: batchId)
                }
            }.resume()
        }
    }

    private func finishPoll(_ outcome: WatchJobOutcome, batchId: String) {
        if outcome != .processing { NSLog("[WatchChunks] job for batch \(batchId): \(outcome)") }
        apply(planner.applyJob(outcome, batchId: batchId, state: &state, now: Date()))
        persist()
        if outcome == .completed || outcome == .notFound { step() }
    }

    /// Deletes confirmed chunks, quarantines unusable ones, and hands acks to WatchConnectivity.
    private func apply(_ effects: WatchSyncPlanner.Effects) {
        let inbox = WatchChunkInbox.shared
        for id in effects.completed {
            try? fileManager.removeItem(at: inbox.directory.appendingPathComponent("\(id).wav"))
            try? fileManager.removeItem(at: inbox.directory.appendingPathComponent("\(id).json"))
        }
        if !effects.quarantined.isEmpty {
            try? fileManager.createDirectory(at: inbox.failedDirectory, withIntermediateDirectories: true)
            for id in effects.quarantined {
                for ext in ["wav", "json"] {
                    let source = inbox.directory.appendingPathComponent("\(id).\(ext)")
                    let target = inbox.failedDirectory.appendingPathComponent("\(id).\(ext)")
                    try? fileManager.removeItem(at: target)
                    try? fileManager.moveItem(at: source, to: target)
                }
            }
        }
        for batchId in effects.finishedBatches { removeUploadBody(batchId) }
        flushAcks()
    }

    private func flushAcks() {
        guard !state.pendingAcks.isEmpty else { return }
        let ids = state.pendingAcks
        // Before WCSession activation (common in a background launch) this returns false;
        // the acks stay queued and go out on the next pass after activation.
        if WatchChunkInbox.shared.ack(chunkIds: ids) {
            state.pendingAcks.removeAll { ids.contains($0) }
            NSLog("[WatchChunks] acked \(ids.count) chunk(s) to the watch")
        }
    }

    // MARK: - Auth + HTTP helpers

    /// Fresh Firebase ID token from the native SDK (the same keychain-backed user the Flutter
    /// plugin uses). Configures the default Firebase app from the options Dart cached if the
    /// app was launched in the background before Dart initialised Firebase.
    private func withIdToken(_ completion: @escaping (String?) -> Void) {
        let force = forceTokenRefresh
        forceTokenRefresh = false
        DispatchQueue.main.async {
            guard self.ensureFirebase(), let user = Auth.auth().currentUser, !user.isAnonymous else {
                completion(nil)
                return
            }
            user.getIDTokenForcingRefresh(force) { token, error in
                if let error { NSLog("[WatchChunks] ID token unavailable: \(error.localizedDescription)") }
                completion(token)
            }
        }
    }

    private func ensureFirebase() -> Bool {
        if FirebaseApp.app() != nil { return true }
        guard let firebase = loadConfig()?.firebase,
              let appId = firebase["appId"], let senderId = firebase["messagingSenderId"],
              let apiKey = firebase["apiKey"], let projectId = firebase["projectId"] else { return false }
        // Same values Dart passes to Firebase.initializeApp, so FlutterFire's duplicate-app
        // check accepts this native default app when Dart starts later.
        let options = FirebaseOptions(googleAppID: appId, gcmSenderID: senderId)
        options.apiKey = apiKey
        options.projectID = projectId
        options.storageBucket = firebase["storageBucket"]
        options.databaseURL = firebase["databaseURL"]
        FirebaseApp.configure(options: options)
        return FirebaseApp.app() != nil
    }

    private func applyHeaders(to request: inout URLRequest, config: Config, token: String) {
        for (name, value) in config.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(String(Date().timeIntervalSince1970), forHTTPHeaderField: "X-Request-Start-Time")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    static func endpoint(_ base: String, _ path: String) -> URL? {
        guard !base.isEmpty else { return nil }
        return URL(string: base.hasSuffix("/") ? base + path : base + "/" + path)
    }

    static func batchId(fromTaskDescription description: String?) -> String? {
        guard let description, description.hasPrefix("upload:") else { return nil }
        return String(description.dropFirst("upload:".count))
    }

    // MARK: - Persistence

    private func loadConfig() -> Config? {
        guard let data = UserDefaults.standard.data(forKey: Self.configDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    private func loadStateIfNeeded() {
        guard !stateLoaded else { return }
        state = WatchSyncStateStore.load(stateURL)
        stateLoaded = true
    }

    private func persist() {
        do { try WatchSyncStateStore.save(state, to: stateURL) } catch {
            NSLog("[WatchChunks] could not save sync state: \(error.localizedDescription)")
        }
    }

    private func removeUploadBody(_ batchId: String) {
        try? fileManager.removeItem(at: uploadsDirectory.appendingPathComponent("\(batchId).body"))
    }

    private func statusSnapshot() -> [String: Any] {
        let stored = scanInbox()
        let done = Set(state.doneIds)
        var snapshot: [String: Any] = [
            "pending": stored.filter { !done.contains($0.chunkId) }.count,
            "uploading": state.batches.filter { $0.phase == .uploading }.flatMap { $0.chunkIds }.count,
            "processing": state.batches.filter { $0.phase == .processing }.flatMap { $0.chunkIds }.count,
            "pendingAcks": state.pendingAcks.count,
            "configured": loadConfig() != nil,
        ]
        if let error = state.lastError { snapshot["lastError"] = error }
        if let next = state.nextUploadAt { snapshot["nextUploadAtMs"] = Int64(next.timeIntervalSince1970 * 1000) }
        return snapshot
    }
}

extension WatchChunkSync: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()
        loadStateIfNeeded()
        guard let batchId = Self.batchId(fromTaskDescription: task.taskDescription) else { return }
        let response = task.response as? HTTPURLResponse
        let outcome: WatchUploadOutcome = error != nil
            ? .transient(error!.localizedDescription)
            : WatchSyncClassifier.classifyUpload(statusCode: response?.statusCode, headers: response?.allHeaderFields ?? [:], body: body)
        NSLog("[WatchChunks] upload \(batchId) finished: \(outcome)")
        if outcome == .unauthorized { forceTokenRefresh = true }
        apply(planner.applyUpload(outcome, batchId: batchId, state: &state, now: Date()))
        persist()
        // Usually running from a background relaunch: hold a short window to confirm the job.
        kick(reason: "upload finished", holdBackgroundTime: true)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        DispatchQueue.main.async { completion?() }
    }
}
