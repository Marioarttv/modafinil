import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

final class WakeAddressProtocolTests: XCTestCase {
    let secret = Data(repeating: 0xa5, count: 32)
    let targets = "02:11:22:33:44:55,00:11:22:33:44:66"
    func state(targets: String?) -> RemoteState {
        RemoteState(awakeRequested: true, sleepPreventionEffective: true,
                    serverName: "Mac", wakeTargetMACs: targets)
    }
    func testV4SignsAndRoundTripsCurrentWakeTargets() throws {
        let signed = RemoteResponse.signed(version: 4, requestID: "test", ok: true,
            state: state(targets: targets), message: "Status", secret: secret)
        let decoded = try RemoteWireCodec.decodeLine(RemoteResponse.self,
            from: RemoteWireCodec.encodeLine(signed))
        XCTAssertEqual(decoded.state?.wakeTargetMACs, targets)
        XCTAssertTrue(decoded.isAuthentic(secret: secret))
        for changed in [nil, "02:11:22:33:44:77"] as [String?] {
            let tampered = RemoteResponse(version: 4, requestID: signed.requestID,
                timestamp: signed.timestamp, ok: true, state: state(targets: changed),
                message: signed.message, signature: signed.signature)
            XCTAssertFalse(tampered.isAuthentic(secret: secret))
        }
    }
    func testOlderPhoneResponsesRemainByteCompatibleAndRejectInjectedTargets() throws {
        for version in [1, 2, 3] {
            let withTargets = RemoteResponse.signed(version: version, requestID: "test", ok: true,
                state: state(targets: targets), message: "Status", secret: secret, timestamp: 1000)
            let withoutTargets = RemoteResponse.signed(version: version, requestID: "test", ok: true,
                state: state(targets: nil), message: "Status", secret: secret, timestamp: 1000)
            XCTAssertEqual(try RemoteWireCodec.encodeLine(withTargets), try RemoteWireCodec.encodeLine(withoutTargets))
            let injected = RemoteResponse(version: version, requestID: withTargets.requestID,
                timestamp: withTargets.timestamp, ok: true, state: state(targets: targets),
                message: withTargets.message, signature: withTargets.signature)
            XCTAssertFalse(injected.isAuthentic(secret: secret))
        }
    }
    func testV4RequestRejectsReplayAndChangedCommand() throws {
        let request = RemoteRequest.signed(version: 4, command: .keepAwake, secret: secret)
        let verifier = RemoteRequestVerifier(secret: secret)
        try verifier.verify(request)
        XCTAssertThrowsError(try verifier.verify(request))
        let changed = RemoteRequest(version: 4, requestID: request.requestID,
            timestamp: request.timestamp, command: .sleep, argument: request.argument,
            signature: request.signature)
        XCTAssertFalse(changed.isAuthentic(secret: secret))
    }

    func testWakeAddressRefreshPreservesEndpointsAndSeparateSecrets() throws {
        let original = PairingConfiguration(displayName: "Mac", macHost: "100.64.1.2",
            relayHost: "100.64.1.3", targetMAC: "02:00:00:00:00:01", secret: secret,
            relaySecret: Data(repeating: 0x5a, count: 32))
        let refreshed = try original.updatingWakeTargets(targets.uppercased())
        XCTAssertEqual(refreshed.targetMAC, targets)
        XCTAssertEqual(refreshed.macHost, original.macHost)
        XCTAssertEqual(refreshed.relayHost, original.relayHost)
        XCTAssertEqual(refreshed.secret, original.secret)
        XCTAssertEqual(refreshed.relaySecret, original.relaySecret)
        XCTAssertEqual(try PairingConfiguration(pairingURL: refreshed.pairingURL), refreshed)
    }
    func testInvalidWakeAddressesCannotReplaceThePairing() {
        for targets in ["", "ff:ff:ff:ff:ff:ff", "01:00:5e:00:00:01", "00:00:00:00:00:00",
            "02:11:22:33:44:55,", "+2:11:22:33:44:55", "02:11:22:33:44", Array(repeating: "02:11:22:33:44:55", count: 5).joined(separator: ",")] {
            XCTAssertNil(PairingConfiguration.normalizedWakeTargets(targets))
        }
    }
}
