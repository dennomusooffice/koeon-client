import XCTest
@testable import KOEON

final class InviteHandoffTests: XCTestCase {
    private let token = String(repeating: "A", count: 43)

    func testParserAcceptsRawTokenAndTrustedUniversalLink() throws {
        XCTAssertEqual(try InviteInputParser.parse(token), token)
        XCTAssertEqual(
            try InviteInputParser.parse("https://example.invalid/join#\(token)"),
            token
        )
    }

    func testParserRejectsWrongHostPathQueryAndMissingFragment() {
        for value in [
            "https://example.com/join#\(token)",
            "https://example.invalid/admin#\(token)",
            "https://example.invalid/join?token=x#\(token)",
            "https://example.invalid/join",
        ] {
            XCTAssertThrowsError(try InviteInputParser.parse(value))
        }
    }

    func testColdAndWarmRoutesAreIndependentAndRetainNoToken() {
        let first = InviteDeepLinkRouter.route(URL(string: "https://example.invalid/join#\(token)")!)
        let secondToken = String(repeating: "B", count: 43)
        let second = InviteDeepLinkRouter.route(URL(string: "https://example.invalid/join#\(secondToken)")!)
        XCTAssertEqual(first, token)
        XCTAssertEqual(second, secondToken)
        XCTAssertNil(InviteDeepLinkRouter.route(URL(string: "https://example.invalid/join")!))
    }

    func testTemporaryCodeNormalizesCaseSpacesAndHyphens() throws {
        XCTAssertEqual(try EnrollmentInputParser.parse("abcde-23456"), .code("ABCDE23456"))
        XCTAssertEqual(try EnrollmentInputParser.parse("ABCDE 23456"), .code("ABCDE23456"))
        XCTAssertThrowsError(try EnrollmentInputParser.parse("ABCDE-I2345"))
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
