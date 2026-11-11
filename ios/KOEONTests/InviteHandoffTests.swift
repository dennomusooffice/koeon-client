import AVFoundation
import XCTest
@testable import KOEON

final class InviteHandoffTests: XCTestCase {
    private let token = String(repeating: "A", count: 43)

    func testParserAcceptsRawTokenAndTrustedUniversalLink() throws {
        XCTAssertEqual(try InviteInputParser.parse(token), token)
        XCTAssertEqual(
            try InviteInputParser.parse("https://koeon.muso-apps.net/join#\(token)"),
            token
        )
    }

    func testParserRejectsWrongHostPathQueryAndMissingFragment() {
        for value in [
            "https://example.com/join#\(token)",
            "https://koeon.muso-apps.net/admin#\(token)",
            "https://koeon.muso-apps.net/join?token=x#\(token)",
            "https://koeon.muso-apps.net/join",
        ] {
            XCTAssertThrowsError(try InviteInputParser.parse(value))
        }
    }

    func testColdAndWarmRoutesAreIndependentAndRetainNoToken() {
        let first = InviteDeepLinkRouter.route(URL(string: "https://koeon.muso-apps.net/join#\(token)")!)
        let secondToken = String(repeating: "B", count: 43)
        let second = InviteDeepLinkRouter.route(URL(string: "https://koeon.muso-apps.net/join#\(secondToken)")!)
        XCTAssertEqual(first, token)
        XCTAssertEqual(second, secondToken)
        XCTAssertNil(InviteDeepLinkRouter.route(URL(string: "https://koeon.muso-apps.net/join")!))
    }

    func testTemporaryCodeNormalizesCaseSpacesAndHyphens() throws {
        XCTAssertEqual(try EnrollmentInputParser.parse("abcde-23456"), .code("ABCDE23456"))
        XCTAssertEqual(try EnrollmentInputParser.parse("ABCDE 23456"), .code("ABCDE23456"))
        XCTAssertThrowsError(try EnrollmentInputParser.parse("ABCDE-I2345"))
    }

    func testChannelChoiceRefreshRejectsOldRuntimeSessionAndScope() {
        let request = ChannelChoiceRefreshScope(sessionId: "session", runtime: 1, userId: "user", workspaceId: "workspace")
        let identity = MeResponse(user: IdentityUser(id: "user", displayName: "Synthetic", role: .staff),
            workspace: IdentityWorkspace(id: "workspace", name: "Synthetic"),
            device: IdentityDevice(id: "device", name: nil, platform: "ios"), channels: [])
        XCTAssertTrue(channelChoicesAreCurrent(requested: request, current: request, identity: identity))
        XCTAssertFalse(channelChoicesAreCurrent(requested: request, current: nil, identity: identity))
        for other in [
            ChannelChoiceRefreshScope(sessionId: "new", runtime: 1, userId: "user", workspaceId: "workspace"),
            ChannelChoiceRefreshScope(sessionId: "session", runtime: 2, userId: "user", workspaceId: "workspace"),
            ChannelChoiceRefreshScope(sessionId: "session", runtime: 1, userId: "other", workspaceId: "workspace"),
            ChannelChoiceRefreshScope(sessionId: "session", runtime: 1, userId: "user", workspaceId: "other")
        ] { XCTAssertFalse(channelChoicesAreCurrent(requested: request, current: other, identity: identity)) }
        let foreign = MeResponse(user: IdentityUser(id: "other", displayName: "Synthetic", role: .staff), workspace: identity.workspace, device: identity.device, channels: [])
        XCTAssertFalse(channelChoicesAreCurrent(requested: request, current: request, identity: foreign))
    }

    func testExplicitChannelNumbersRejectAmbiguity() {
        XCTAssertEqual(ChannelSwitchPolicy.number(12), 12)
        XCTAssertEqual(ChannelSwitchPolicy.number(0), 0)
        for n in [-1, 100] { XCTAssertNil(ChannelSwitchPolicy.number(n)) }
        let one = Channel(id: "one", workspaceId: "scope", name: "CH99 misleading", channelNumber: 12)
        let two = Channel(id: "two", workspaceId: "scope", name: "Other", channelNumber: 12)
        XCTAssertNil(ChannelSwitchPolicy.numbered([Channel(id: "old", workspaceId: "scope", name: "CH12")], number: 12))
        XCTAssertEqual(ChannelSwitchPolicy.numbered([one], number: 12), one)
        XCTAssertNil(ChannelSwitchPolicy.numbered([one, two], number: 12))
        XCTAssertNil(ChannelSwitchPolicy.numbered([one], number: 1))
    }

    func testChannelNumberDecodingAndDigitPlaces() throws {
        for suffix in ["", ",\"channelNumber\":null", ",\"channelNumber\":12"] {
            let data = Data("{\"id\":\"synthetic\",\"name\":\"CH99\"\(suffix)}".utf8)
            let channel = try JSONDecoder().decode(Channel.self, from: data)
            XCTAssertEqual(channel.channelNumber, suffix.hasSuffix("12") ? 12 : nil)
        }
        for (n, ones, tens) in [(1, 1, nil as Int?), (12, 2, 1), (11, 1, 1), (10, 0, 1), (99, 9, 9)] {
            let digits = ChannelSwitchPolicy.digits(number: n, entry: nil, count: 1)
            XCTAssertEqual(digits.ones, ones); XCTAssertEqual(digits.tens, tens)
        }
        let partial = ChannelSwitchPolicy.digits(number: 2, entry: "1", count: 2)
        XCTAssertNil(partial.ones); XCTAssertEqual(partial.tens, 1)
    }

    func testUnassignedEntryCanConfirmButCannotResolveAChannel() {
        XCTAssertTrue(ChannelSwitchPolicy.canConfirm(entry: "9", count: 1, named: false))
        XCTAssertTrue(ChannelSwitchPolicy.canConfirm(entry: "99", count: 2, named: false))
        XCTAssertFalse(ChannelSwitchPolicy.canConfirm(entry: "9", count: 2, named: false))
        XCTAssertFalse(ChannelSwitchPolicy.canConfirm(entry: nil, count: 1, named: false))
        XCTAssertFalse(ChannelSwitchPolicy.canConfirm(entry: "", count: 1, named: false))
        XCTAssertTrue(ChannelSwitchPolicy.canConfirm(entry: "", count: 1, named: true))
        XCTAssertNil(ChannelSwitchPolicy.numbered([], number: 99))
    }

    func testChannelSelectorHasStableOrderAndWraps() {
        let channels = [
            Channel(id: "reception", workspaceId: "w", name: "04 受付"),
            Channel(id: "stage", workspaceId: "w", name: "02 ステージ"),
            Channel(id: "operations", workspaceId: "w", name: "01 運営本部"),
        ]
        XCTAssertEqual(ChannelSwitchPolicy.ordered(channels).map(\.id), ["operations", "stage", "reception"])
        XCTAssertEqual(ChannelSwitchPolicy.adjacent(channels, currentId: "reception", direction: 1), "operations")
        XCTAssertEqual(ChannelSwitchPolicy.adjacent(channels, currentId: "operations", direction: -1), "reception")
    }
}

final class ReceiveLevelMeterTests: XCTestCase {
    func testLiveInputMeterFollowsFrameAndTransmissionLifetime() {
        let suite = "live-meter-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let processor = InputGainProcessor(defaults: defaults)
        processor.setMode(.off)
        var samples: [Float] = [16384, -16384]
        func process() { samples.withUnsafeMutableBufferPointer { buffer in
            processor.processFloatS16(channels: 1, frames: buffer.count) { _ in buffer.baseAddress! }
        } }
        process()
        XCTAssertNil(processor.currentLevelDbfs())
        processor.beginTransmission()
        process()
        XCTAssertEqual(processor.currentLevelDbfs()!, -6.0206, accuracy: 0.001)
        samples = [0, 0]; process()
        XCTAssertEqual(processor.currentLevelDbfs()!, -96)
        XCTAssertNil(processor.currentLevelDbfs(now: ProcessInfo.processInfo.systemUptime + 0.4))
        processor.endTransmission(learn: false)
        XCTAssertNil(processor.currentLevelDbfs())
        processor.beginTransmission()
        XCTAssertNil(processor.currentLevelDbfs())
    }

    private func pcm(_ value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
        buffer.frameLength = 8
        for index in 0..<8 { buffer.floatChannelData![0][index] = value }
        return buffer
    }
    func testRmsSilenceNonFiniteAndFreshness() {
        XCTAssertEqual(ReceiveLevelMeter.rmsDbfs(pcm(0.5))!, -6.0206, accuracy: 0.001)
        XCTAssertEqual(ReceiveLevelMeter.rmsDbfs(pcm(0))!, -96)
        XCTAssertNil(ReceiveLevelMeter.rmsDbfs(pcm(.nan)))
        let meter = ReceiveLevelMeter()
        meter.record(pcm(0.5), now: 1)
        XCTAssertNil(meter.value(now: 1))
        meter.setEnabled(true)
        meter.record(pcm(0.5), now: 1)
        meter.record(pcm(0), now: 1.05)
        XCTAssertEqual(meter.value(now: 1.05)!, -6.0206, accuracy: 0.001)
        XCTAssertNil(meter.value(now: 1.301))
        XCTAssertNil(meter.value(now: 0.9))
        meter.setEnabled(false)
        meter.record(pcm(0.5), now: 2)
        XCTAssertNil(meter.value(now: 2))
        meter.setEnabled(true)
        XCTAssertNil(meter.value(now: 2))
    }
    func testInterleavedPcm16AndUnsupportedFormat() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
        buffer.frameLength = 8
        for index in 0..<16 { buffer.int16ChannelData![0][index] = 16384 }
        XCTAssertEqual(ReceiveLevelMeter.rmsDbfs(buffer)!, -6.0206, accuracy: 0.001)
        buffer.frameLength = 0
        XCTAssertNil(ReceiveLevelMeter.rmsDbfs(buffer))
        let unsupported = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48000, channels: 1, interleaved: false)!, frameCapacity: 8)!
        unsupported.frameLength = 8
        XCTAssertNil(ReceiveLevelMeter.rmsDbfs(unsupported))
    }
}
