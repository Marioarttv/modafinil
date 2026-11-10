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

    func setScheduledWake(
        _ timestamp: Double,
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
                proxy.setScheduledWake(timestamp) { success, message in
                    if success {
                        finish(.success(()))
                    } else {
                        finish(.failure(HelperError(message ?? "The helper could not update the wake schedule (update or re-enable the Mac helper if needed).")))
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

    /// Asks a helper left over from before an update to make room (see the helper).
    /// `completion(true)`: it is exiting, and the next call starts the installed one.
    /// A helper older than 0.14.0 does not know the call and counts as not retiring.
    func retireIfReplaced(completion: @escaping (Bool) -> Void) {
        var didComplete = false
        let finish: (Bool) -> Void = { retired in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                if retired { self.invalidate() }
                completion(retired)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
        remoteProxy { result in
            switch result {
            case .failure: finish(false)
            case .success(let proxy): proxy.retireIfReplaced { finish($0) }
            }
        }
    }

    /// Before uninstalling: the sleep blockers a sleep switched off count again.
    func confirmSleepBlockersRestored(completion: @escaping (Result<Void, Error>) -> Void) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            finish(.failure(HelperError("The helper did not confirm that sleep blockers are back in effect.")))
        }
        remoteProxy { result in
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let proxy):
                proxy.confirmSleepBlockersRestored { success, message in
                    finish(success ? .success(()) : .failure(HelperError(message ?? "Sleep blockers could not be switched back on.")))
                }
            }
        }
    }

    /// - Parameter local: Sleep Now at this Mac (the click must not cancel it).
    func sleepAfterDisablingSleepPrevention(
        local: Bool = false,
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
                let reply: (Bool, String?) -> Void = { success, message in
                    if success {
                        finish(.success(()))
                    } else {
                        finish(.failure(HelperError(message ?? "The helper could not put the Mac to sleep.")))
                    }
                }
                if local { proxy.requestLocalSleep(withReply: reply) }
                else { proxy.requestTrackedSleep(withReply: reply) }
            }
        }
    }

    func setSleepTimer(after seconds: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            finish(.failure(HelperError("The helper did not confirm the sleep timer. Update Modafinil and its helper on this Mac.")))
        }
        remoteProxy { result in
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let proxy):
                proxy.setSleepTimer(after: seconds) { success, message in
                    finish(success ? .success(()) : .failure(HelperError(message ?? "Could not update the sleep timer.")))
                }
            }
        }
    }

    func canShutDown(completion: @escaping (Result<Void, Error>) -> Void) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            finish(.failure(HelperError("The helper did not answer. Open Modafinil on this Mac so it updates its helper.")))
        }
        remoteProxy { result in
            switch result {
            case .failure(let error): finish(.failure(HelperError("Could not reach the helper (\(error.localizedDescription)). Open Modafinil on this Mac; it may need to update its helper.")))
            case .success(let proxy):
                proxy.canShutDown { success, message in
                    finish(success ? .success(()) : .failure(HelperError(message ?? "The helper cannot shut the Mac down.")))
                }
            }
        }
    }

    func shutDownNow(completion: @escaping (Result<Void, Error>) -> Void) {
        var didComplete = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            finish(.failure(HelperError("The helper did not confirm the shutdown. Update Modafinil and its helper on this Mac.")))
        }
        remoteProxy { result in
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let proxy):
                proxy.shutDownNow { success, message in
                    finish(success ? .success(()) : .failure(HelperRefused(message: message ?? "The helper could not shut the Mac down.")))
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

    /// The helper answered and refused (as opposed to no answer at all).
    struct HelperRefused: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct HelperError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
