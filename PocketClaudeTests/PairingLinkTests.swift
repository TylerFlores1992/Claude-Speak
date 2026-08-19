import XCTest
@testable import PocketClaude

/// A pairing link fills in the relay address and token in one tap. Getting it
/// half-right is worse than not applying it at all — settings pointing at a
/// relay with the wrong token read as "the relay is broken" — so these mostly
/// check what is *refused*.
final class PairingLinkTests: XCTestCase {

    func testParsesACompleteLink() throws {
        let url = try XCTUnwrap(URL(string: "pocketclaude://pair?url=http://100.119.76.63:8788&token=abc123"))
        let link = try XCTUnwrap(PairingLink(url))
        XCTAssertEqual(link.relayURL, "http://100.119.76.63:8788")
        XCTAssertEqual(link.token, "abc123")
    }

    func testRoundTripsThroughMake() throws {
        let made = try XCTUnwrap(PairingLink.make(relayURL: "http://mini-pc:8788", token: "a b/c+d=e"))
        let parsed = try XCTUnwrap(PairingLink(made))
        // The token is the awkward case: percent-encoding has to survive both
        // directions or pairing silently sets a wrong token.
        XCTAssertEqual(parsed.token, "a b/c+d=e")
        XCTAssertEqual(parsed.relayURL, "http://mini-pc:8788")
    }

    func testRefusesAMissingToken() throws {
        let url = try XCTUnwrap(URL(string: "pocketclaude://pair?url=http://host:8788"))
        XCTAssertNil(PairingLink(url))
    }

    func testRefusesAMissingAddress() throws {
        let url = try XCTUnwrap(URL(string: "pocketclaude://pair?token=abc"))
        XCTAssertNil(PairingLink(url))
    }

    func testRefusesAnAddressWithNoScheme() throws {
        let url = try XCTUnwrap(URL(string: "pocketclaude://pair?url=mini-pc:8788&token=abc"))
        XCTAssertNil(PairingLink(url), "a bare host:port should fail at the tap, not later")
    }

    func testIgnoresOtherLinks() throws {
        for other in [
            "https://example.com/pair?url=http://host&token=abc",
            "pocketclaude://something-else?url=http://host&token=abc",
        ] {
            let url = try XCTUnwrap(URL(string: other))
            XCTAssertNil(PairingLink(url), "should ignore \(other)")
        }
    }
}

/// `URL(string:)` is far more permissive than it looks — `mini-pc:8788` parses
/// with scheme `mini-pc`. That made `url.scheme != nil` accept an address no
/// request could be sent to, in four places at once.
final class RelayAddressTests: XCTestCase {

    func testAcceptsHTTPAndHTTPS() {
        XCTAssertTrue(RelayAddress.isUsable("http://100.119.76.63:8788"))
        XCTAssertTrue(RelayAddress.isUsable("https://relay.example.com"))
        XCTAssertTrue(RelayAddress.isUsable("  http://mini-pc:8788  "), "should tolerate padding")
    }

    func testRefusesABareHostAndPort() {
        // The case that slipped through: this parses as scheme "mini-pc".
        XCTAssertFalse(RelayAddress.isUsable("mini-pc:8788"))
        XCTAssertFalse(RelayAddress.isUsable("100.119.76.63:8788"))
    }

    func testRefusesOtherSchemes() {
        for address in ["ftp://host", "file:///etc/passwd", "ws://host:8788"] {
            XCTAssertFalse(RelayAddress.isUsable(address), "should refuse \(address)")
        }
    }

    func testRefusesASchemeWithNoHost() {
        XCTAssertFalse(RelayAddress.isUsable("http://"))
        XCTAssertFalse(RelayAddress.isUsable(""))
    }
}
