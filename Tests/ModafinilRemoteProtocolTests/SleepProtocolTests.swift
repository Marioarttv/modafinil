import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

final class SleepProtocolTests: XCTestCase {
    let secret = Data(repeating: 0xa5, count: 32)
    var state: RemoteState {
        RemoteState(awakeRequested: false, sleepPreventionEffective: false, serverName: "Mac",
            scheduledWakeAt: 5000, sleepAttempt: RemoteSleepAttempt(requestedAt: 1000,
                phase: .failed, detail: "OS error\nwith separators: \u{1f}"))
    }
    func testV3RoundTripSignsSleepResult() throws {
        let response = RemoteResponse.signed(version: 3, requestID: "test", ok: true, state: state, message: "Status", secret: secret)
        let decoded = try RemoteWireCodec.decodeLine(RemoteResponse.self, from: RemoteWireCodec.encodeLine(response))
        XCTAssertEqual(response, decoded); XCTAssertTrue(decoded.isAuthentic(secret: secret))
    }
    func testLegacyResponsesStripUnsupportedFields() {
        for version in [1, 2] {
            let response = RemoteResponse.signed(version: version, requestID: "test", ok: true, state: state, message: "Status", secret: secret)
            XCTAssertNil(response.state?.sleepAttempt)
            XCTAssertEqual(response.state?.scheduledWakeAt, version == 1 ? nil : 5000)
            XCTAssertTrue(response.isAuthentic(secret: secret))
        }
    }
    func testLegacyResponseRejectsUnsignedSleepResult() {
        let signed = RemoteResponse.signed(version: 2, requestID: "test", ok: true, state: state, message: "Status", secret: secret)
        let injected = RemoteResponse(version: 2, requestID: signed.requestID, timestamp: signed.timestamp,
            ok: true, state: state, message: signed.message, signature: signed.signature)
        XCTAssertFalse(injected.isAuthentic(secret: secret))
    }
    func testV3RejectsChangedOrRemovedResult() {
        let signed = RemoteResponse.signed(version: 3, requestID: "test", ok: true, state: state, message: "Status", secret: secret)
        let changed = RemoteState(awakeRequested: false, sleepPreventionEffective: false, serverName: "Mac", scheduledWakeAt: 5000)
        let tampered = RemoteResponse(version: 3, requestID: signed.requestID, timestamp: signed.timestamp,
            ok: true, state: changed, message: signed.message, signature: signed.signature)
        XCTAssertFalse(tampered.isAuthentic(secret: secret))
    }
    func testAllSupportedVersionsAuthenticateRequests() throws {
        for version in [1, 2, 3] {
            let request = RemoteRequest.signed(version: version, command: .status, secret: secret)
            XCTAssertNoThrow(try RemoteRequestVerifier(secret: secret).verify(request))
        }
    }
}
