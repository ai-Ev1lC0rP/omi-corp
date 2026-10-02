import AVFoundation
import Combine
import Foundation
import UserNotifications
import WatchConnectivity
import WatchKit
import os

/// Store-and-forward Apple Watch recorder.
///
/// The watch always records locally into rolling WAV chunks (`ChunkedCaptureEngine`) and is
/// the source of truth for audio. Finished chunks are queued to the phone with
/// `WCSession.transferFile`, which the system delivers whenever the phone becomes reachable
/// (it survives disconnects, app suspension and relaunch). A chunk is deleted only after the
/// phone sends a `chunkAck` saying it was uploaded and transcribed. There is no live audio
/// stream any more, so a phone/watch connect or disconnect can no longer stop listening.
@MainActor
final class WatchAudioRecorderViewModel: NSObject, WatchRecorderControlling {
    static let wantsRecordingDefaultsKey = "omi.watch.wantsRecording"
    /// Re-send a delivered-but-unacknowledged chunk after this long (phone lost it, reinstall, ...).
    static let redeliverAfter: TimeInterval = 6 * 60 * 60
    static let maxQueuedTransfers = 40

    @Published var isRecording: Bool = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var pendingChunkCount: Int = 0
    @Published private(set) var pendingBytes: Int64 = 0
    @Published private(set) var droppedChunkCount: Int = 0
    @Published private(set) var lastAckAt: Date?
    @Published private(set) var isPhoneReachable: Bool = false
    @Published private(set) var statusNote: String?

    var session: WCSession
    private let store: WatchChunkStore
    private let capture: ChunkedCaptureEngine
    private let logger = Logger(subsystem: "com.casonclark.omi.watchapp", category: "recorder")
    private var pumpTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var needsResume = false

    init(session: WCSession = .default, store: WatchChunkStore = WatchChunkStore()) {
        self.session = session
        self.store = store
        self.capture = ChunkedCaptureEngine(store: store)
        super.init()

        capture.onChunkCommitted = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let dropped = self.store.enforceStorageCap()
                if !dropped.isEmpty { self.logger.warning("dropped \(dropped.count) chunk(s) over storage cap") }
                self.refreshStatus()
                self.pumpTransfers()
            }
        }
        capture.onEngineStopped = { [weak self] reason in
            Task { @MainActor in self?.handleEngineStopped(reason: reason) }
        }

        if WCSession.isSupported() {
            self.session.delegate = self
            self.session.activate()
        }
        observeAudioSession()

        capture.recoverOrphans()
        refreshStatus()

        BatteryManager.shared.startBatteryMonitoring()
        BatteryManager.shared.sendWatchInfo()

        pumpTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
                self?.pumpTransfers()
            }
        }

        if UserDefaults.standard.bool(forKey: Self.wantsRecordingDefaultsKey) {
            // Resume the user's intent after a relaunch. Audio I/O can only start while the
            // app is active; `appBecameActive()` retries if this attempt is too early.
            isRecording = true
            startCapture()
        }
    }

    // MARK: - Public controls

    func startRecording() {
        UserDefaults.standard.set(true, forKey: Self.wantsRecordingDefaultsKey)
        isRecording = true
        requestNotificationPermissionIfNeeded()
        startCapture()
    }

    func stopRecording() {
        UserDefaults.standard.set(false, forKey: Self.wantsRecordingDefaultsKey)
        isRecording = false
        needsResume = false
        capture.stop()
        isCapturing = false
        recordingStartedAt = nil
        statusNote = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sendIfReachable(["method": "stopRecording"])
        refreshStatus()
        pumpTransfers()
    }

    /// Scene became active (app opened, wrist raised onto the app, notification tapped).
    func appBecameActive() {
        refreshStatus()
        pumpTransfers()
        if isRecording && !capture.isRunning {
            startCapture()
        }
    }

    // MARK: - Capture lifecycle

    private func startCapture() {
        guard !capture.isRunning else {
            isCapturing = true
            return
        }
        checkMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.isCapturing = false
                self.statusNote = "Microphone access denied"
                self.sendIfReachable(["method": "recordingError", "error": "Microphone permission denied"])
                return
            }
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // playAndRecord + mixWithOthers: only calls/alarms interrupt us.
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
                try audioSession.setActive(true, options: [])
                try self.capture.start()
                self.isCapturing = true
                self.needsResume = false
                self.statusNote = nil
                if self.recordingStartedAt == nil { self.recordingStartedAt = Date() }
                self.sendIfReachable(["method": "startRecording"])
                self.logger.info("recording started")
            } catch {
                self.isCapturing = false
                self.needsResume = true
                self.statusNote = "Paused — open Omi to resume"
                self.logger.error("capture start failed: \(error.localizedDescription, privacy: .public)")
                if WKApplication.shared().applicationState != .active {
                    self.scheduleResumeNotification()
                }
            }
        }
    }

    private func handleEngineStopped(reason: String) {
        isCapturing = false
        guard isRecording else { return }
        logger.warning("engine stopped (\(reason, privacy: .public)); restarting")
        startCapture()
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeValue: typeValue) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.capture.handleInterruptionBegan()
                self.handleEngineStopped(reason: "mediaServicesReset")
            }
        })
    }

    private func handleInterruption(typeValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            logger.info("audio interruption began")
            capture.handleInterruptionBegan()
            isCapturing = false
            if isRecording { statusNote = "Interrupted" }
        case .ended:
            logger.info("audio interruption ended")
            guard isRecording else { return }
            startCapture()
        @unknown default:
            break
        }
    }

    private func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default:
            completion(false)
        }
    }

    func requestMicrophonePermissionOnly() {
        checkMicrophonePermission { [weak self] granted in
            self?.sendIfReachable(["method": "microphonePermissionResult", "granted": granted])
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleResumeNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Omi paused"
        content.body = "Recording stopped. Open Omi on your watch to resume."
        let request = UNNotificationRequest(identifier: "omi.watch.resume", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Sync

    private func refreshStatus() {
        let chunks = store.pendingChunks()
        pendingChunkCount = chunks.count
        pendingBytes = chunks.reduce(0) { $0 + $1.byteCount }
        droppedChunkCount = store.droppedChunkCount
        isPhoneReachable = WCSession.isSupported() && session.isReachable
        isCapturing = capture.isRunning
    }

    /// Queue every unacknowledged chunk that is not already in flight, oldest first.
    func pumpTransfers() {
        guard WCSession.isSupported(), session.activationState == .activated, session.isCompanionAppInstalled else { return }
        let inFlight = Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?["chunkId"] as? String })
        var queued = inFlight.count
        let now = Date()
        for chunk in store.pendingChunks() {
            guard queued < Self.maxQueuedTransfers else { break }
            if inFlight.contains(chunk.chunkId) { continue }
            if let delivered = chunk.transferDeliveredAt, now.timeIntervalSince(delivered) < Self.redeliverAfter { continue }
            session.transferFile(store.audioURL(for: chunk.chunkId), metadata: chunk.transferMetadata)
            store.update(chunk.chunkId) {
                $0.transferQueuedAt = now
                $0.transferDeliveredAt = nil
                $0.transferAttempts += 1
            }
            queued += 1
        }
    }

    private func handleAck(_ message: [String: Any]) {
        let ids = (message["chunkIds"] as? [String]) ?? []
        guard !ids.isEmpty else { return }
        let deleted = store.delete(chunkIds: ids)
        lastAckAt = Date()
        logger.info("phone acknowledged \(ids.count) chunk(s); deleted \(deleted)")
        refreshStatus()
    }

    private func handleTransferFinished(chunkId: String?, error: Error?) {
        guard let chunkId else { return }
        if let error {
            logger.warning("transfer of \(chunkId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            store.update(chunkId) { $0.transferQueuedAt = nil }
        } else {
            store.update(chunkId) { $0.transferDeliveredAt = Date() }
        }
        refreshStatus()
    }

    private func handleCommand(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        switch method {
        case "startRecording":
            startRecording()
        case "stopRecording":
            stopRecording()
        case "requestMicrophonePermission":
            requestMicrophonePermissionOnly()
        case "requestBattery":
            BatteryManager.shared.sendBatteryLevel()
        case "requestWatchInfo":
            BatteryManager.shared.sendWatchInfo()
        case "chunkAck":
            handleAck(message)
        case "chunkConfig":
            if let seconds = message["chunkSeconds"] as? Double {
                UserDefaults.standard.set(seconds, forKey: ChunkedCaptureEngine.chunkSecondsDefaultsKey)
                capture.setChunkSeconds(seconds)
            }
            if let maxBytes = message["maxStorageBytes"] as? Int64 {
                UserDefaults.standard.set(maxBytes, forKey: WatchChunkStore.maxStorageDefaultsKey)
            }
        default:
            logger.debug("unknown method \(method, privacy: .public)")
        }
    }

    private func sendIfReachable(_ message: [String: Any]) {
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }
}

extension WatchAudioRecorderViewModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in
            self.refreshStatus()
            self.pumpTransfers()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshStatus()
            self.pumpTransfers()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        let chunkId = fileTransfer.file.metadata?["chunkId"] as? String
        let failure = error
        Task { @MainActor in self.handleTransferFinished(chunkId: chunkId, error: failure) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handleCommand(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.handleCommand(userInfo) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.handleCommand(applicationContext) }
    }
}
