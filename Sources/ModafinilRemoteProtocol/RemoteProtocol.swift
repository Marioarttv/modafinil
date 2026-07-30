import CryptoKit
import Foundation
import Security

public enum RemoteCommand: String, Codable, Sendable {
    case status
    case keepAwake
    case sleep
    case wake
}

public struct RemoteState: Codable, Equatable, Sendable {
    public let awakeRequested: Bool
    public let sleepPreventionEffective: Bool
    public let serverName: String

    public init(
        awakeRequested: Bool,
        sleepPreventionEffective: Bool,
        serverName: String
    ) {
        self.awakeRequested = awakeRequested
        self.sleepPreventionEffective = sleepPreventionEffective
        self.serverName = serverName
    }
}

public struct RemoteRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: String
    public let timestamp: Int64
    public let command: RemoteCommand
    public let argument: String
    public let signature: String

    public init(
        version: Int = Self.currentVersion,
        requestID: String,
        timestamp: Int64,
        command: RemoteCommand,
        argument: String,
        signature: String
    ) {
        self.version = version
        self.requestID = requestID
        self.timestamp = timestamp
        self.command = command
        self.argument = argument
        self.signature = signature
    }

    public static func signed(
        command: RemoteCommand,
        argument: String = "",
        secret: Data,
        requestID: String = UUID().uuidString.lowercased(),
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Self {
        let unsigned = Self(
            requestID: requestID,
            timestamp: timestamp,
            command: command,
            argument: argument,
            signature: ""
        )
        return Self(
            requestID: requestID,
            timestamp: timestamp,
            command: command,
            argument: argument,
            signature: RemoteAuthentication.signature(
                for: unsigned.canonicalPayload,
                secret: secret
            )
        )
    }

    public var canonicalPayload: Data {
        Data(
            [
                String(version),
                requestID,
                String(timestamp),
                command.rawValue,
                argument
            ]
            .joined(separator: "\n")
            .utf8
        )
    }

    public func isAuthentic(secret: Data) -> Bool {
        version == Self.currentVersion &&
            RemoteAuthentication.isValid(
                signature: signature,
                payload: canonicalPayload,
                secret: secret
            )
    }
}

public struct RemoteResponse: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: String
    public let timestamp: Int64
    public let ok: Bool
    public let state: RemoteState?
    public let message: String
    public let signature: String

    public init(
        version: Int = Self.currentVersion,
        requestID: String,
        timestamp: Int64,
        ok: Bool,
        state: RemoteState?,
        message: String,
        signature: String
    ) {
        self.version = version
        self.requestID = requestID
        self.timestamp = timestamp
        self.ok = ok
        self.state = state
        self.message = message
        self.signature = signature
    }

    public static func signed(
        requestID: String,
        ok: Bool,
        state: RemoteState? = nil,
        message: String,
        secret: Data,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Self {
        let unsigned = Self(
            requestID: requestID,
            timestamp: timestamp,
            ok: ok,
            state: state,
            message: message,
            signature: ""
        )
        return Self(
            requestID: requestID,
            timestamp: timestamp,
            ok: ok,
            state: state,
            message: message,
            signature: RemoteAuthentication.signature(
                for: unsigned.canonicalPayload,
                secret: secret
            )
        )
    }

    public var canonicalPayload: Data {
        let statePayload: String
        if let state {
            statePayload = [
                state.awakeRequested ? "1" : "0",
                state.sleepPreventionEffective ? "1" : "0",
                state.serverName
            ].joined(separator: "\u{1f}")
        } else {
            statePayload = ""
        }

        return Data(
            [
                String(version),
                requestID,
                String(timestamp),
                ok ? "1" : "0",
                statePayload,
                message
            ]
            .joined(separator: "\n")
            .utf8
        )
    }

    public func isAuthentic(secret: Data) -> Bool {
        version == Self.currentVersion &&
            RemoteAuthentication.isValid(
                signature: signature,
                payload: canonicalPayload,
                secret: secret
            )
    }
}

public enum RemoteAuthentication {
    public static func generateSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
    }

    public static func signature(for payload: Data, secret: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: secret)
        )
        return Data(code).hexEncodedString
    }

    public static func isValid(
        signature: String,
        payload: Data,
        secret: Data
    ) -> Bool {
        guard let suppliedCode = Data(hexEncoded: signature) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            suppliedCode,
            authenticating: payload,
            using: SymmetricKey(data: secret)
        )
    }
}

public final class RemoteRequestVerifier: @unchecked Sendable {
    private let secret: Data
    private let allowedClockSkew: Int64
    private let replayRetention: Int64
    private let lock = NSLock()
    private var acceptedRequestIDs: [String: Int64] = [:]

    public init(
        secret: Data,
        allowedClockSkew: Int64 = 90,
        replayRetention: Int64 = 300
    ) {
        precondition(secret.count == 32, "Remote secrets must contain 256 bits")
        self.secret = secret
        self.allowedClockSkew = allowedClockSkew
        self.replayRetention = replayRetention
    }

    public func verify(
        _ request: RemoteRequest,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws {
        guard request.version == RemoteRequest.currentVersion else {
            throw VerificationError.unsupportedVersion
        }
        guard UUID(uuidString: request.requestID) != nil else {
            throw VerificationError.invalidRequestID
        }
        guard request.argument.utf8.count <= 256 else {
            throw VerificationError.argumentTooLarge
        }
        guard
            request.timestamp >= now - allowedClockSkew,
            request.timestamp <= now + allowedClockSkew
        else {
            throw VerificationError.timestampOutsideWindow
        }
        guard request.isAuthentic(secret: secret) else {
            throw VerificationError.invalidSignature
        }

        lock.lock()
        defer { lock.unlock() }

        acceptedRequestIDs = acceptedRequestIDs.filter {
            $0.value >= now - replayRetention
        }
        guard acceptedRequestIDs[request.requestID] == nil else {
            throw VerificationError.replayedRequest
        }
        acceptedRequestIDs[request.requestID] = now
    }

    public enum VerificationError: LocalizedError, Equatable {
        case unsupportedVersion
        case invalidRequestID
        case argumentTooLarge
        case timestampOutsideWindow
        case invalidSignature
        case replayedRequest

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion:
                return "The request protocol version is unsupported."
            case .invalidRequestID:
                return "The request identifier is invalid."
            case .argumentTooLarge:
                return "The request argument is too large."
            case .timestampOutsideWindow:
                return "The request timestamp is outside the allowed window."
            case .invalidSignature:
                return "The request signature is invalid."
            case .replayedRequest:
                return "The request has already been accepted."
            }
        }
    }
}

public enum RemoteWireCodec {
    public static let maximumMessageSize = 16_384

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0a)
        return data
    }

    public static func decodeLine<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        guard data.count <= maximumMessageSize else {
            throw WireError.messageTooLarge
        }

        let payload: Data
        if data.last == 0x0a {
            payload = data.dropLast()
        } else {
            payload = data
        }
        return try decoder.decode(type, from: payload)
    }

    public enum WireError: LocalizedError {
        case messageTooLarge

        public var errorDescription: String? {
            "The remote message exceeded the size limit."
        }
    }
}

public extension Data {
    init?(hexEncoded string: String) {
        guard string.count.isMultiple(of: 2) else { return nil }

        var data = Data()
        data.reserveCapacity(string.count / 2)
        var index = string.startIndex

        while index < string.endIndex {
            let nextIndex = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
