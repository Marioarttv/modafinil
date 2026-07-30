import Foundation
import ModafinilRemoteProtocol
import Network

protocol CompanionServerDelegate: AnyObject {
    func companionServerCurrentState(_ server: CompanionServer) -> RemoteState

    func companionServer(
        _ server: CompanionServer,
        perform command: RemoteCommand,
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    )
}

final class CompanionServer {
    weak var delegate: CompanionServerDelegate?
    var errorHandler: ((String) -> Void)?

    private var secret: Data
    private let queue = DispatchQueue(label: "com.narcotic.modafinil.companion")
    private var requestVerifier: RemoteRequestVerifier
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    init(secret: Data) {
        self.secret = secret
        requestVerifier = RemoteRequestVerifier(secret: secret)
    }

    func start() throws {
        guard listener == nil else { return }

        let port = NWEndpoint.Port(rawValue: CompanionConfigurationStore.macPort)!
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.report(error: "Companion listener failed: \(error.localizedDescription)")
                self?.listener?.cancel()
                self?.listener = nil
            case .waiting(let error):
                self?.report(error: "Companion listener is waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.activeConnections.values.forEach { $0.cancel() }
            self.activeConnections.removeAll()
        }
    }

    func updateSecret(_ secret: Data) {
        queue.async {
            self.secret = secret
            self.requestVerifier = RemoteRequestVerifier(secret: secret)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isAllowedPeer(connection.endpoint) else {
            NSLog("Modafinil rejected companion connection from non-Tailscale peer")
            connection.cancel()
            return
        }

        guard activeConnections.count < 32 else {
            connection.cancel()
            return
        }

        let connectionID = ObjectIdentifier(connection)
        activeConnections[connectionID] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.activeConnections[connectionID] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak connection] in
            connection?.cancel()
        }
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4_096
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let data {
                buffer.append(data)
            }

            guard buffer.count <= RemoteWireCodec.maximumMessageSize else {
                connection.cancel()
                return
            }

            if let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let nextIndex = buffer.index(after: newlineIndex)
                guard nextIndex == buffer.endIndex else {
                    connection.cancel()
                    return
                }

                handleRequestLine(buffer, connection: connection)
                return
            }

            guard !isComplete else {
                connection.cancel()
                return
            }

            receiveRequest(on: connection, buffer: buffer)
        }
    }

    private func handleRequestLine(_ data: Data, connection: NWConnection) {
        let request: RemoteRequest
        do {
            request = try RemoteWireCodec.decodeLine(RemoteRequest.self, from: data)
        } catch {
            connection.cancel()
            return
        }

        let responseSecret = secret
        do {
            try requestVerifier.verify(request)
        } catch {
            send(
                requestID: request.requestID,
                ok: false,
                state: nil,
                message: error.localizedDescription,
                secret: responseSecret,
                on: connection
            )
            return
        }

        perform(
            request: request,
            responseSecret: responseSecret,
            connection: connection
        )
    }

    private func perform(
        request: RemoteRequest,
        responseSecret: Data,
        connection: NWConnection
    ) {
        guard request.command != .wake else {
            send(
                requestID: request.requestID,
                ok: false,
                state: nil,
                message: "Wake requests must be sent to the iPhone relay.",
                secret: responseSecret,
                on: connection
            )
            return
        }

        guard let delegate else {
            send(
                requestID: request.requestID,
                ok: false,
                state: nil,
                message: "Modafinil is not ready.",
                secret: responseSecret,
                on: connection
            )
            return
        }

        if request.command == .status {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                let state = delegate.companionServerCurrentState(self)
                self.queue.async {
                    self.send(
                        requestID: request.requestID,
                        ok: true,
                        state: state,
                        message: "Status updated.",
                        secret: responseSecret,
                        on: connection
                    )
                }
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }

            delegate.companionServer(self, perform: request.command) { result in
                self.queue.async {
                    switch result {
                    case .success(let (state, message)):
                        self.send(
                            requestID: request.requestID,
                            ok: true,
                            state: state,
                            message: message,
                            secret: responseSecret,
                            on: connection
                        )
                    case .failure(let error):
                        self.send(
                            requestID: request.requestID,
                            ok: false,
                            state: nil,
                            message: error.localizedDescription,
                            secret: responseSecret,
                            on: connection
                        )
                    }
                }
            }
        }
    }

    private func send(
        requestID: String,
        ok: Bool,
        state: RemoteState?,
        message: String,
        secret: Data,
        on connection: NWConnection
    ) {
        let response = RemoteResponse.signed(
            requestID: requestID,
            ok: ok,
            state: state,
            message: message,
            secret: secret
        )

        do {
            let data = try RemoteWireCodec.encodeLine(response)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            connection.cancel()
        }
    }

    private func report(error: String) {
        NSLog("Modafinil \(error)")
        DispatchQueue.main.async { [weak self] in
            self?.errorHandler?(error)
        }
    }

    private static func isAllowedPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }

        var address = host.debugDescription
        if let scopeIndex = address.firstIndex(of: "%") {
            address = String(address[..<scopeIndex])
        }
        address = address.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )

        if let ipv4 = IPv4Address(address) {
            let bytes = [UInt8](ipv4.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 127 ||
                (bytes[0] == 100 && (64...127).contains(bytes[1]))
        }

        if let ipv6 = IPv6Address(address) {
            let bytes = [UInt8](ipv6.rawValue)
            guard bytes.count == 16 else { return false }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } &&
                bytes.last == 1
            let isTailscale = Array(bytes.prefix(6)) == [
                0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0
            ]
            return isLoopback || isTailscale
        }

        return false
    }
}
