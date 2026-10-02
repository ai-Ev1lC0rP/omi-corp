import Foundation
import WatchConnectivity
import AVFoundation
import Flutter

class RecorderHostApiImpl: WatchRecorderHostAPI {
    let session: WCSession
    weak var flutterWatchAPI: WatchRecorderFlutterAPI?

    init(session: WCSession = .default, flutterWatchAPI: WatchRecorderFlutterAPI? = nil) {
        self.session = session
        self.flutterWatchAPI = flutterWatchAPI
    }

    func startRecording() {

        if session.isReachable {
            session.sendMessage(["method": "startRecording"], replyHandler: nil, errorHandler: { error in
                try? self.session.updateApplicationContext(["method": "startRecording"])
            })
        } else {
            try? session.updateApplicationContext(["method": "startRecording"])
        }
    }

    func stopRecording() {

        if session.isReachable {
            session.sendMessage(["method": "stopRecording"], replyHandler: nil, errorHandler: { error in
                try? self.session.updateApplicationContext(["method": "stopRecording"])
            })
        } else {
            try? session.updateApplicationContext(["method": "stopRecording"])
        }
    }

    func sendAudioData(audioData: FlutterStandardTypedData) {
        let data = audioData.data as Data
        session.sendMessage(["method": "sendAudioData", "audioData": data], replyHandler: nil, errorHandler: nil)
    }

    func sendAudioChunk(audioChunk: FlutterStandardTypedData, chunkIndex: Int64, isLast: Bool, sampleRate: Double) {
        let data = audioChunk.data as Data
        session.sendMessage([
            "method": "sendAudioChunk",
            "audioChunk": data,
            "chunkIndex": chunkIndex,
            "isLast": isLast,
            "sampleRate": sampleRate
        ], replyHandler: nil, errorHandler: nil)
    }

    func isWatchPaired() -> Bool { session.isPaired }
    func isWatchReachable() -> Bool { session.isReachable }
    func isWatchSessionSupported() -> Bool { WCSession.isSupported() }
    func isWatchAppInstalled() -> Bool { session.isWatchAppInstalled }

    func requestWatchMicrophonePermission() {
        if session.isReachable {
            session.sendMessage(["method": "requestMicrophonePermission"], replyHandler: nil, errorHandler: { error in
                try? self.session.updateApplicationContext(["method": "requestMicrophonePermission"])
            })
        } else {
            try? session.updateApplicationContext(["method": "requestMicrophonePermission"])
        }
    }

    func requestMainAppMicrophonePermission() {
        let audioSession = AVAudioSession.sharedInstance()
        let permissionStatus = audioSession.recordPermission

        switch permissionStatus {
        case .granted:
            DispatchQueue.main.async {
                self.flutterWatchAPI?.onMainAppMicrophonePermissionResult(granted: true) { _ in
                }
            }
        case .denied:
            DispatchQueue.main.async {
                self.flutterWatchAPI?.onMainAppMicrophonePermissionResult(granted: false) { _ in
                }
            }
        case .undetermined:
            audioSession.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.flutterWatchAPI?.onMainAppMicrophonePermissionResult(granted: granted) { _ in
                    }
                }
            }
        @unknown default:
            DispatchQueue.main.async {
                self.flutterWatchAPI?.onMainAppMicrophonePermissionResult(granted: false) { _ in
                }
            }
        }
    }

    func checkMainAppMicrophonePermission() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        let hasPermission = audioSession.recordPermission == .granted
        return hasPermission
    }
    
    func getWatchBatteryLevel() -> Double {
        let batteryLevel = UserDefaults.standard.double(forKey: "watch_battery_level")
        return batteryLevel
    }
    
    func getWatchBatteryState() -> Int64 {
        let batteryState = UserDefaults.standard.integer(forKey: "watch_battery_state")
        return Int64(batteryState)
    }
    
    func requestWatchBatteryUpdate() {
        
        if session.isReachable {
            session.sendMessage(["method": "requestBattery"], replyHandler: nil, errorHandler: { error in
                // Fallback for background/unreachable scenarios
                self.session.transferUserInfo(["method": "requestBattery"])
            })
        } else {
            session.transferUserInfo(["method": "requestBattery"])
        }
    }
    
    func getWatchInfo() -> [String: String] {
        
        // Get cached watch info from UserDefaults (updated by watch messages)
        let name = UserDefaults.standard.string(forKey: "watch_device_name") ?? "Apple Watch"
        let model = UserDefaults.standard.string(forKey: "watch_device_model") ?? "Unknown"
        let systemVersion = UserDefaults.standard.string(forKey: "watch_system_version") ?? "Unknown"
        let localizedModel = UserDefaults.standard.string(forKey: "watch_localized_model") ?? "Unknown"
        
        let deviceInfo: [String: String] = [
            "name": name,
            "model": model,
            "systemVersion": systemVersion,
            "localizedModel": localizedModel
        ]
        
        // Also request fresh info from watch
        if session.isReachable {
            session.sendMessage(["method": "requestWatchInfo"], replyHandler: nil, errorHandler: { error in
                // Fallback for background/unreachable scenarios
                self.session.transferUserInfo(["method": "requestWatchInfo"])
            })
        } else {
            session.transferUserInfo(["method": "requestWatchInfo"])
        }
        
        return deviceInfo
    }
}



/// Phone-side landing zone for Apple Watch store-and-forward audio chunks.
///
/// The watch queues each finished chunk with `WCSession.transferFile`; iOS delivers it here
/// even when the app was launched in the background. The file must be moved before the
/// delegate call returns, so this class persists it natively (audio + JSON sidecar, the
/// sidecar being the commit marker) and only then pokes Dart, which uploads chunks through
/// `/v2/sync-local-files` and asks us to acknowledge them back to the watch.
final class WatchChunkInbox {
    static let shared = WatchChunkInbox()
    static let channelName = "com.omi.watch/chunks"

    private var channel: FlutterMethodChannel?
    private let fileManager = FileManager.default

    var directory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("watch_chunks", isDirectory: true)
    }

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
            case "ackChunks":
                let ids = (arguments?["chunkIds"] as? [String]) ?? []
                result(self.ack(chunkIds: ids))
            case "configureWatch":
                var payload: [String: Any] = ["method": "chunkConfig"]
                if let seconds = arguments?["chunkSeconds"] as? Double { payload["chunkSeconds"] = seconds }
                if let maxBytes = arguments?["maxStorageBytes"] as? Int { payload["maxStorageBytes"] = Int64(maxBytes) }
                result(self.send(payload))
            case "isWatchAppInstalled":
                let session = WCSession.default
                result(WCSession.isSupported() && session.activationState == .activated && session.isPaired && session.isWatchAppInstalled)
            case "beginBackgroundTask":
                var taskId: UIBackgroundTaskIdentifier = .invalid
                taskId = UIApplication.shared.beginBackgroundTask(withName: "omi.watchChunkUpload") {
                    UIApplication.shared.endBackgroundTask(taskId)
                }
                result(taskId.rawValue)
            case "endBackgroundTask":
                if let raw = arguments?["taskId"] as? Int {
                    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
                }
                result(nil)
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
              Self.isSafeChunkId(chunkId) else {
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
        DispatchQueue.main.async {
            self.channel?.invokeMethod("chunkReceived", arguments: chunkId)
        }
    }

    /// Tell the watch these chunks are uploaded + transcribed so it can delete them.
    /// transferUserInfo is queued and survives disconnects; sendMessage is the fast path.
    @discardableResult
    func ack(chunkIds: [String]) -> Bool {
        let ids = chunkIds.filter(Self.isSafeChunkId)
        guard !ids.isEmpty else { return false }
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

    static func isSafeChunkId(_ chunkId: String) -> Bool {
        !chunkId.isEmpty && chunkId.count < 128
            && chunkId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
