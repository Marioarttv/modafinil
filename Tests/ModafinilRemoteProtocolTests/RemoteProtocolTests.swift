import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

final class RemoteProtocolTests: XCTestCase {
    private let secret = Data(repeating: 0xa5, count: 32)
    private let relaySecret = Data(repeating: 0x5a, count: 32)

    func testProtocolMatchesKnownCompanionVector() {
        let request = RemoteRequest.signed(
            command: .keepAwake,
            argument: "120",
            secret: secret,
            requestID: "request-1",
            timestamp: 1_750_000_000
        )

        XCTAssertEqual(
            request.signature,
            "be151e91e6485538cd2d3359918dcc6c6b31b9d36446a47419b721cf0d6773b1"
        )
        XCTAssertTrue(request.isAuthentic(secret: secret))
    }

    func testReplayAndTimestampEnforcement() {
        let verifier = RemoteRequestVerifier(secret: secret)
        let now: Int64 = 1_750_000_000
        let request = RemoteRequest.signed(
            command: .status,
            secret: secret,
            requestID: "00000000-0000-4000-8000-000000000002",
            timestamp: now
        )

        XCTAssertNoThrow(try verifier.verify(request, now: now))
        assertVerificationFailure(
            try verifier.verify(request, now: now),
            equals: .replayedRequest
        )

        let stale = RemoteRequest.signed(
            command: .status,
            secret: secret,
            requestID: "00000000-0000-4000-8000-000000000003",
            timestamp: now - 91
        )
        assertVerificationFailure(
            try verifier.verify(stale, now: now),
            equals: .timestampOutsideWindow
        )
    }

    func testTamperingIsRejected() {
        let request = RemoteRequest.signed(
            command: .status,
            secret: secret,
            requestID: "00000000-0000-4000-8000-000000000004",
            timestamp: 1_750_000_000
        )
        let tampered = RemoteRequest(
            requestID: request.requestID,
            timestamp: request.timestamp,
            command: .sleep,
            argument: request.argument,
            signature: request.signature
        )

        let verifier = RemoteRequestVerifier(secret: secret)
        assertVerificationFailure(
            try verifier.verify(tampered, now: request.timestamp),
            equals: .invalidSignature
        )
    }

    func testWireSizeLimit() {
        let oversized = Data(repeating: 0x61, count: RemoteWireCodec.maximumMessageSize + 1)

        XCTAssertThrowsError(
            try RemoteWireCodec.decodeLine(RemoteRequest.self, from: oversized)
        )
    }

    func testPairingRoundTripPreservesMultipleWakeMACs() throws {
        let configuration = PairingConfiguration(
            displayName: "MacBook",
            macHost: "100.64.1.2",
            relayHost: "100.64.1.3",
            targetMAC: "aa:bb:cc:dd:ee:ff,11:22:33:44:55:66",
            secret: secret,
            relaySecret: relaySecret
        )

        XCTAssertEqual(
            try PairingConfiguration(pairingURL: configuration.pairingURL),
            configuration
        )
    }

    func testPairingURLRejectsDuplicateKeys() {
        let encodedSecret = secret.base64EncodedString()
        let encodedRelaySecret = relaySecret.base64EncodedString()
        let url = URL(
            string: """
            modafinil://pair?v=2&v=2&name=Mac&macHost=127.0.0.1&macPort=48765&relayHost=127.0.0.1&relayPort=48766&targetMAC=aa:bb:cc:dd:ee:02&secret=\(encodedSecret)&relaySecret=\(encodedRelaySecret)
            """
        )!

        XCTAssertThrowsError(try PairingConfiguration(pairingURL: url))
    }

    func testScheduledSleepIsCoveredByStateSignature() {
        let state = RemoteState(
            awakeRequested: true,
            sleepPreventionEffective: true,
            serverName: "MacBook",
            scheduledSleepAt: 1_750_003_600
        )
        let response = RemoteResponse.signed(
            requestID: "00000000-0000-4000-8000-000000000005",
            ok: true,
            state: state,
            message: "Timer set",
            secret: secret,
            timestamp: 1_750_000_000
        )
        XCTAssertTrue(response.isAuthentic(secret: secret))

        let tampered = RemoteResponse(
            requestID: response.requestID,
            timestamp: response.timestamp,
            ok: response.ok,
            state: RemoteState(
                awakeRequested: true,
                sleepPreventionEffective: true,
                serverName: "MacBook",
                scheduledSleepAt: 1_750_007_200
            ),
            message: response.message,
            signature: response.signature
        )
        XCTAssertFalse(tampered.isAuthentic(secret: secret))
    }

    private func assertVerificationFailure(
        _ expression: @autoclosure () throws -> Void,
        equals expectedError: RemoteRequestVerifier.VerificationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try expression()
            XCTFail("Expected verification to fail", file: file, line: line)
        } catch let error as RemoteRequestVerifier.VerificationError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
