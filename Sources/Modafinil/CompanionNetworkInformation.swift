import Darwin
import Foundation

struct CompanionNetworkInformation {
    let tailscaleIPv4: String?
    let wifiInterface: String?
    let wifiMACAddress: String?

    static func discover() -> Self {
        let wifiInterface = discoverWiFiInterface()
        return Self(
            tailscaleIPv4: discoverTailscaleIPv4(),
            wifiInterface: wifiInterface,
            wifiMACAddress: wifiInterface.flatMap(currentMACAddress)
        )
    }

    private static func discoverTailscaleIPv4() -> String? {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else {
            return nil
        }
        defer { freeifaddrs(firstInterface) }

        var interface: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = interface {
            defer { interface = current.pointee.ifa_next }

            guard
                current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                let address = current.pointee.ifa_addr
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            let value = String(cString: host)
            if isTailscaleIPv4(value) {
                return value
            }
        }

        return nil
    }

    private static func isTailscaleIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func discoverWiFiInterface() -> String? {
        guard let output = try? Shell.run(
            "/usr/sbin/networksetup",
            ["-listallhardwareports"]
        ) else {
            return nil
        }

        for block in output.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: .newlines)
            guard lines.contains(where: { $0 == "Hardware Port: Wi-Fi" }) else {
                continue
            }

            return lines
                .first { $0.hasPrefix("Device: ") }?
                .dropFirst("Device: ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func currentMACAddress(interface: String) -> String? {
        guard let output = try? Shell.run("/sbin/ifconfig", [interface]) else {
            return nil
        }

        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "ether" else { continue }

            let candidate = String(fields[1]).lowercased()
            guard isMACAddress(candidate) else { continue }
            return candidate
        }

        return nil
    }

    private static func isMACAddress(_ value: String) -> Bool {
        let bytes = value.split(separator: ":")
        return bytes.count == 6 && bytes.allSatisfy {
            $0.count == 2 && UInt8($0, radix: 16) != nil
        }
    }
}
