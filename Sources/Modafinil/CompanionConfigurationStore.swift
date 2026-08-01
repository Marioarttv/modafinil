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
        static let legacySecret = "companion.secret"
        static let relayHost = "companion.relayHost"
        static let relayPort = "companion.relayPort"
        static let targetMACs = "companion.targetMACs"
        static let wakeArmed = "companion.wakeArmed"
        static let batteryWakeWindowsArmed = "companion.batteryWakeWindowsArmed"
        static let batteryWakeNextWindowAt = "companion.batteryWakeNextWindowAt"
        static let batteryWakeWindowsRemaining = "companion.batteryWakeWindowsRemaining"
    }

    private enum KeychainAccount {
        static let macSecret = "companion-secret"
        static let relaySecret = "companion-relay-secret"
    }

    private let defaults: UserDefaults
    private let keychain = CompanionSecretKeychain()
    private var cachedSecret: Data
    private var cachedRelaySecret: Data

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cachedSecret = Self.loadOrCreateSecret(
            keychain: keychain,
            account: KeychainAccount.macSecret,
            legacyDefaults: defaults
        )
        cachedRelaySecret = Self.loadOrCreateSecret(
            keychain: keychain,
            account: KeychainAccount.relaySecret,
            legacyDefaults: nil
        )
    }

    /// Authenticates iPhone commands to this Mac's listener.
    var secret: Data { cachedSecret }

    /// Authenticates iPhone wake requests to the XR relay. Kept separate so
    /// a compromise of the jailbroken relay phone cannot control this Mac.
    var relaySecret: Data { cachedRelaySecret }

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

    var areBatteryWakeWindowsArmed: Bool {
        get { defaults.bool(forKey: Key.batteryWakeWindowsArmed) }
        set {
            defaults.set(newValue, forKey: Key.batteryWakeWindowsArmed)
            defaults.synchronize()
        }
    }

    var batteryWakeNextWindowDate: Date? {
        get {
            let timestamp = defaults.double(forKey: Key.batteryWakeNextWindowAt)
            guard timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.batteryWakeNextWindowAt)
            } else {
                defaults.removeObject(forKey: Key.batteryWakeNextWindowAt)
            }
            defaults.synchronize()
        }
    }

    var batteryWakeWindowsRemaining: Int {
        get { defaults.integer(forKey: Key.batteryWakeWindowsRemaining) }
        set {
            defaults.set(newValue, forKey: Key.batteryWakeWindowsRemaining)
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

    func resetSecrets() {
        cachedSecret = RemoteAuthentication.generateSecret()
        cachedRelaySecret = RemoteAuthentication.generateSecret()
        keychain.setSecret(cachedSecret, account: KeychainAccount.macSecret)
        keychain.setSecret(cachedRelaySecret, account: KeychainAccount.relaySecret)
        NotificationCenter.default.post(
            name: .modafinilCompanionConfigurationDidChange,
            object: self
        )
    }

    func deleteSecrets() {
        keychain.deleteSecret(account: KeychainAccount.macSecret)
        keychain.deleteSecret(account: KeychainAccount.relaySecret)
        defaults.removeObject(forKey: Key.legacySecret)
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
            secret: secret,
            relaySecret: relaySecret
        )
    }

    private static func loadOrCreateSecret(
        keychain: CompanionSecretKeychain,
        account: String,
        legacyDefaults: UserDefaults?
    ) -> Data {
        if let existing = keychain.secret(account: account), existing.count == 32 {
            return existing
        }

        if let legacyDefaults,
           let legacy = legacyDefaults.data(forKey: Key.legacySecret),
           legacy.count == 32
        {
            if keychain.setSecret(legacy, account: account) {
                legacyDefaults.removeObject(forKey: Key.legacySecret)
            }
            return legacy
        }

        let secret = RemoteAuthentication.generateSecret()
        keychain.setSecret(secret, account: account)
        return secret
    }
}
