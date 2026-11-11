// Isolated device investigation only. Replaces App/KOEONApp.swift in a TEMPORARY
// source copy. Never add this file to the product target. No recording or network.
import SwiftUI
import PushToTalk
import AVFoundation

@main
struct AccessoryProbeApp: App {
    @StateObject private var probe = AccessoryProbe()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 24) {
                Text("Accessory Probe — No Audio")
                Text(probe.status).accessibilityIdentifier("probe-status")
                Text("Begin \(probe.begins) / End \(probe.ends) / Handsfree \(probe.handsfree)")
                Button("Join Probe") { Task { await probe.join() } }
                Button("Control Begin (3s)") { probe.beginControl() }
                Button("Leave Probe") { probe.leave() }
            }.padding()
        }
    }
}

@MainActor
final class AccessoryProbe: NSObject, ObservableObject, PTChannelManagerDelegate, PTChannelRestorationDelegate {
    @Published var status = "IDLE"
    @Published var begins = 0
    @Published var ends = 0
    @Published var handsfree = 0
    private var manager: PTChannelManager?
    private let channel = UUID(uuidString: "17CB1441-E0C9-461A-9D5F-1B5FC154A2B6")!
    private var stopTask: Task<Void, Never>?
    private var sequence = 0
    private var lastSource = -1
    private var activated = 0
    private func save() {
        let data: [String: Any] = ["status": status, "begin": begins, "end": ends,
            "handsfree": handsfree, "source": lastSource, "activated": activated,
            "capturedAt": ISO8601DateFormatter().string(from: Date())]
        guard let bytes = try? JSONSerialization.data(withJSONObject: data),
              let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? bytes.write(to: dir.appendingPathComponent("accessory-probe.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func join() async {
        do {
            if manager == nil { manager = try await PTChannelManager.channelManager(delegate: self, restorationDelegate: self) }
            guard let manager else { return }
            guard manager.activeChannelUUID == nil else { status = "EXISTING_CHANNEL_LEAVE_FIRST"; save(); return }
            // Configuration only; NEVER activate, start an engine, or capture audio.
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            status = "JOINING"; save()
            manager.requestJoinChannel(channelUUID: channel, descriptor: PTChannelDescriptor(name: "Accessory Probe", image: nil))
        } catch { status = "JOIN_ERROR_\((error as NSError).code)"; save() }
    }
    func beginControl() { manager?.requestBeginTransmitting(channelUUID: channel) }
    func leave() {
        stopTask?.cancel(); sequence += 1
        if let id = manager?.activeChannelUUID { manager?.leaveChannel(channelUUID: id) }
    }
    nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        PTChannelDescriptor(name: "Accessory Probe", image: nil)
    }
    nonisolated func channelManager(_ manager: PTChannelManager, didJoinChannel id: UUID, reason: PTChannelJoinReason) {
        Task { @MainActor in
            guard id == channel else { status = "EXISTING_CHANNEL_LEAVE_FIRST"; save(); return }
            do {
                try await manager.setTransmissionMode(.halfDuplex, channelUUID: id)
                try await manager.setServiceStatus(.ready, channelUUID: id)
                try await manager.setAccessoryButtonEventsEnabled(true, channelUUID: id)
                status = "JOINED_ACCESSORY_ENABLED"; save()
            } catch { status = "CONFIG_ERROR_\((error as NSError).code)"; save() }
        }
    }
    nonisolated func channelManager(_ manager: PTChannelManager, didLeaveChannel id: UUID, reason: PTChannelLeaveReason) {
        Task { @MainActor in stopTask?.cancel(); sequence += 1; status = "LEFT"; save() }
    }
    nonisolated func channelManager(_ manager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {}
    nonisolated func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult { .leaveChannel }
    nonisolated func channelManager(_ manager: PTChannelManager, channelUUID id: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in
            guard id == channel else { return }
            begins += 1; lastSource = source.rawValue
            if source == .handsfreeButton { handsfree += 1 }
            status = "BEGAN_NO_AUDIO"; sequence += 1; let attempt = sequence; save()
            stopTask?.cancel()
            stopTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard sequence == attempt else { return }
                manager.stopTransmitting(channelUUID: id)
            }
        }
    }
    nonisolated func channelManager(_ manager: PTChannelManager, channelUUID id: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in stopTask?.cancel(); sequence += 1; ends += 1; status = "ENDED"; save() }
    }
    nonisolated func channelManager(_ manager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in activated += 1; save() }
    }
    nonisolated func channelManager(_ manager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {}
    nonisolated func channelManager(_ manager: PTChannelManager, failedToBeginTransmittingInChannel id: UUID, error: Error) {
        Task { @MainActor in status = "BEGIN_ERROR_\((error as NSError).code)"; save() }
    }
    nonisolated func channelManager(_ manager: PTChannelManager, failedToJoinChannel id: UUID, error: Error) {
        Task { @MainActor in status = "JOIN_ERROR_\((error as NSError).code)"; save() }
    }
}
