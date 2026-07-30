import Foundation
import ModafinilRemoteProtocol

extension Notification.Name {
    static let modafinilCompanionConfigurationDidChange = Notification.Name(
        "com.narcotic.modafinil.companionConfigurationDidChange"
    )
}

final class CompanionConfigurationStore {
    static let macPort: UInt16 = 48_765
    static let defaultRelayPort: UInt16 = 48_766

    private enum Key {
        static let secret = "companion.secret"
        static let relayHost = "companion.relayHost"
        static let relayPort = "companion.relayPort"
        static let targetMACs = "companion.targetMACs"
        static let wakeArmed = "companion.wakeArmed"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ensureSecretExists()
    }

    var secret: Data {
        guard let secret = defaults.data(forKey: Key.secret), secret.count == 32 else {
            let secret = RemoteAuthentication.generateSecret()
            defaults.set(secret, forKey: Key.secret)
            return secret
        }
        return secret
    }

    var relayHost: String {
        defaults.string(forKey: Key.relayHost) ?? ""
    }

    var relayPort: UInt16 {
        let storedValue = defaults.integer(forKey: Key.relayPort)
        guard storedValue > 0, let port = UInt16(exactly: storedValue) else {
            return Self.defaultRelayPort
        }
        return port
    }

    var configuredTargetMACs: String? {
        defaults.string(forKey: Key.targetMACs)
    }

    var isWakeArmed: Bool {
        get { defaults.bool(forKey: Key.wakeArmed) }
        set {
            defaults.set(newValue, forKey: Key.wakeArmed)
            defaults.synchronize()
        }
    }

    func updatePairing(
        relayHost: String,
        relayPort: UInt16,
        targetMACs: String
    ) {
        defaults.set(
            relayHost.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Key.relayHost
        )
        defaults.set(Int(relayPort), forKey: Key.relayPort)
        defaults.set(
            targetMACs.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Key.targetMACs
        )
        NotificationCenter.default.post(
            name: .modafinilCompanionConfigurationDidChange,
            object: self
        )
    }

    func resetSecret() {
        defaults.set(RemoteAuthentication.generateSecret(), forKey: Key.secret)
        NotificationCenter.default.post(
            name: .modafinilCompanionConfigurationDidChange,
            object: self
        )
    }

    func pairingConfiguration(
        networkInformation: CompanionNetworkInformation
    ) -> PairingConfiguration {
        PairingConfiguration(
            displayName: Host.current().localizedName ?? "Mac",
            macHost: networkInformation.tailscaleIPv4 ?? "",
            macPort: Self.macPort,
            relayHost: relayHost,
            relayPort: relayPort,
            targetMAC: configuredTargetMACs ??
                networkInformation.wifiMACAddress ??
                "",
            secret: secret
        )
    }

    private func ensureSecretExists() {
        guard defaults.data(forKey: Key.secret)?.count != 32 else { return }
        defaults.set(RemoteAuthentication.generateSecret(), forKey: Key.secret)
    }
}
