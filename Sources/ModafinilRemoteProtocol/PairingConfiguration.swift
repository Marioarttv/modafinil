import Foundation

public struct PairingConfiguration: Codable, Equatable, Sendable {
    public static let scheme = "modafinil"
    public static let host = "pair"

    public let displayName: String
    public let macHost: String
    public let macPort: UInt16
    public let relayHost: String
    public let relayPort: UInt16
    public let targetMAC: String
    public let secret: Data
    public let relaySecret: Data

    public init(
        displayName: String,
        macHost: String,
        macPort: UInt16 = 48_765,
        relayHost: String,
        relayPort: UInt16 = 48_766,
        targetMAC: String,
        secret: Data,
        relaySecret: Data
    ) {
        self.displayName = displayName
        self.macHost = macHost
        self.macPort = macPort
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.targetMAC = targetMAC
        self.secret = secret
        self.relaySecret = relaySecret
    }

    public init(pairingURL: URL) throws {
        guard
            pairingURL.scheme == Self.scheme,
            pairingURL.host == Self.host,
            let components = URLComponents(url: pairingURL, resolvingAgainstBaseURL: false)
        else {
            throw PairingError.invalidLink
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values[item.name] == nil else {
                throw PairingError.invalidLink
            }
            values[item.name] = value
        }

        guard
            values["v"] == "2",
            let displayName = values["name"],
            let macHost = values["macHost"],
            let macPortText = values["macPort"],
            let macPort = UInt16(macPortText),
            let relayHost = values["relayHost"],
            let relayPortText = values["relayPort"],
            let relayPort = UInt16(relayPortText),
            let targetMAC = values["targetMAC"],
            let secretText = values["secret"],
            let secret = Data(base64Encoded: secretText),
            secret.count == 32,
            let relaySecretText = values["relaySecret"],
            let relaySecret = Data(base64Encoded: relaySecretText),
            relaySecret.count == 32
        else {
            throw PairingError.missingConfiguration
        }

        self.init(
            displayName: displayName,
            macHost: macHost,
            macPort: macPort,
            relayHost: relayHost,
            relayPort: relayPort,
            targetMAC: targetMAC,
            secret: secret,
            relaySecret: relaySecret
        )
    }

    public var pairingURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "name", value: displayName),
            URLQueryItem(name: "macHost", value: macHost),
            URLQueryItem(name: "macPort", value: String(macPort)),
            URLQueryItem(name: "relayHost", value: relayHost),
            URLQueryItem(name: "relayPort", value: String(relayPort)),
            URLQueryItem(name: "targetMAC", value: targetMAC),
            URLQueryItem(name: "secret", value: secret.base64EncodedString()),
            URLQueryItem(name: "relaySecret", value: relaySecret.base64EncodedString())
        ]
        return components.url!
    }

    public enum PairingError: LocalizedError {
        case invalidLink
        case missingConfiguration

        public var errorDescription: String? {
            switch self {
            case .invalidLink:
                return "This is not a Modafinil pairing link."
            case .missingConfiguration:
                return "The pairing link is incomplete or invalid."
            }
        }
    }
}
