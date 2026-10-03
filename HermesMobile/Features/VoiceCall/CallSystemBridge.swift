import AVFoundation
import CallKit

/// The CallKit side of a voice call: one outgoing call to "Atlas", kept out of
/// Recents. CallKit activates the audio session; recognition starts after that.
@MainActor
final class CallSystemBridge: NSObject, CallSystemBridging, CXProviderDelegate {
    var onEnded: (() -> Void)?
    var onMuteChanged: ((Bool) -> Void)?
    var onHoldChanged: ((Bool) -> Void)?

    static let handle = "Atlas"

    private let provider: CXProvider
    private let controller = CXCallController()
    private var callID: UUID?
    private var activation: CheckedContinuation<Void, Error>?

    enum BridgeError: Error {
        case ended
    }

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.includesCallsInRecents = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func startCall() async throws {
        let id = UUID()
        callID = id
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: Self.handle))
        action.isVideo = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activation = continuation
            controller.request(CXTransaction(action: action)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.finishActivation(throwing: error) }
            }
        }
    }

    func endCall() {
        guard let callID else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: callID))) { _ in }
    }

    func setMuted(_ muted: Bool) {
        guard let callID else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))) { _ in }
    }

    private func finishActivation(throwing error: Error?) {
        guard let activation else { return }
        self.activation = nil
        if let error { activation.resume(throwing: error) } else { activation.resume() }
    }

    private func callEnded() {
        callID = nil
        finishActivation(throwing: BridgeError.ended)
        onEnded?()
    }

    // MARK: - CXProviderDelegate (delivered on the main queue)

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { callEnded() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
            } catch {
                action.fail()
                finishActivation(throwing: error)
                return
            }
            let update = CXCallUpdate()
            update.remoteHandle = action.handle
            update.localizedCallerName = Self.handle
            update.hasVideo = false
            update.supportsHolding = true
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportCall(with: action.callUUID, updated: update)
            provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            action.fulfill()
            if action.callUUID == callID { callEnded() }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            action.fulfill()
            onMuteChanged?(action.isMuted)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        MainActor.assumeIsolated {
            action.fulfill()
            onHoldChanged?(action.isOnHold)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { finishActivation(throwing: nil) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
