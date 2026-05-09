import Foundation
import ModafinilShared

final class PrivilegedHelperClient {
    private var connection: NSXPCConnection?
    private let requestTimeout: TimeInterval = 5

    func setSleepPreventionEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard !didComplete else { return }
            self?.invalidate()
            finish(.failure(HelperError("The helper did not respond.")))
        }

        remoteProxy { proxyResult in
            switch proxyResult {
            case .failure(let error):
                finish(.failure(error))
            case .success(let proxy):
                proxy.setSleepPreventionEnabled(enabled) { success, message in
                    if success {
                        finish(.success(()))
                    } else {
                        finish(.failure(HelperError(message ?? "The helper could not change the sleep setting.")))
                    }
                }
            }
        }
    }

    func getSleepPreventionStatus(
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        var didComplete = false
        let finish: (Result<Bool, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard !didComplete else { return }
            self?.invalidate()
            finish(.failure(HelperError("The helper did not respond.")))
        }

        remoteProxy { proxyResult in
            switch proxyResult {
            case .failure(let error):
                finish(.failure(error))
            case .success(let proxy):
                proxy.getSleepPreventionStatus { success, enabled, message in
                    if success {
                        finish(.success(enabled))
                    } else {
                        finish(.failure(HelperError(message ?? "The helper could not read the sleep setting.")))
                    }
                }
            }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func remoteProxy(
        completion: @escaping (Result<ModafinilHelperProtocol, Error>) -> Void
    ) {
        let connection = self.connection ?? makeConnection()
        self.connection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                self.invalidate()
                completion(.failure(error))
            }
        }

        guard let typedProxy = proxy as? ModafinilHelperProtocol else {
            completion(.failure(HelperError("Could not create the helper XPC proxy.")))
            return
        }

        completion(.success(typedProxy))
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: ModafinilConstants.helperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: ModafinilHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.connection = nil
            }
        }
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.connection = nil
            }
        }
        connection.resume()
        return connection
    }

    struct HelperError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
