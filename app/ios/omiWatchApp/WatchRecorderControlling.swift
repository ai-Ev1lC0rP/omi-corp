import Combine
import Foundation

@MainActor
protocol WatchRecorderControlling: ObservableObject {
    var isRecording: Bool { get }
    var recordingStartedAt: Date? { get }
    /// Microphone actually running (false while interrupted/paused).
    var isCapturing: Bool { get }
    /// Finished chunks still waiting for the phone's uploaded+transcribed acknowledgement.
    var pendingChunkCount: Int { get }
    var pendingBytes: Int64 { get }
    var droppedChunkCount: Int { get }
    var isPhoneReachable: Bool { get }
    var statusNote: String? { get }

    func startRecording()
    func stopRecording()
    func appBecameActive()
}
