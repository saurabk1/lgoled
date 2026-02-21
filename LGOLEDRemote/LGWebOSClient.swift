import Foundation

protocol WebSocketTransporting: AnyObject {
    func connect() async throws
    func send(text: String) async throws
    func receive() async throws -> String
    func disconnect()
}

final class URLSessionWebSocketTransport: NSObject, WebSocketTransporting {
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(url: URL) {
        self.url = url
    }

    func connect() async throws {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        guard let session else { throw LGWebOSError.transport("Failed to create URLSession") }
        task = session.webSocketTask(with: url)
        task?.resume()
    }

    func send(text: String) async throws {
        guard let task else { throw LGWebOSError.notConnected }
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        guard let task else { throw LGWebOSError.notConnected }
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            throw LGWebOSError.invalidResponse
        }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}

extension URLSessionWebSocketTransport: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        // Accept self-signed certs from the TV (LG webOS uses self-signed TLS on port 3001)
        return (.useCredential, URLCredential(trust: trust))
    }
}

protocol LGWebOSControlling: AnyObject {
    var onConnectionStateChange: ((ConnectionState) -> Void)? { get set }
    var onRuntimeState: ((TVRuntimeState) -> Void)? { get set }
    var onLastError: ((String) -> Void)? { get set }

    func connect(to tv: LGTVDevice, forcePairing: Bool) async throws
    func disconnect() async
    func powerOff() async throws
    func volumeUp() async throws
    func volumeDown() async throws
    func toggleMute() async throws
    func channelUp() async throws
    func channelDown() async throws
    func sendButton(_ name: String) async throws
    func launchApp(_ appId: String) async throws
    func switchInput(_ inputId: String) async throws
    func queryRuntimeState() async throws -> TVRuntimeState
}

final class LGWebOSClient: LGWebOSControlling {
    var onConnectionStateChange: ((ConnectionState) -> Void)?
    var onRuntimeState: ((TVRuntimeState) -> Void)?
    var onLastError: ((String) -> Void)?

    private let logger: Logger
    private let keyStore: ClientKeyStore
    private let transportFactory: (URL) -> WebSocketTransporting

    private var transport: WebSocketTransporting?
    private var receiveTask: Task<Void, Never>?
    private var requestCounter: Int = 0
    private var runtimeState = TVRuntimeState()
    private var pending: [String: CheckedContinuation<LGWebOSResponse, Error>] = [:]
    private let lock = NSLock()

    // Tracks the request ID of the active registration so handle() can distinguish
    // the intermediate PROMPT "response" from a genuine command response.
    private var pendingRegistrationID: String?

    init(
        keyStore: ClientKeyStore,
        logger: Logger,
        transportFactory: @escaping (URL) -> WebSocketTransporting = { URLSessionWebSocketTransport(url: $0) }
    ) {
        self.keyStore = keyStore
        self.logger = logger
        self.transportFactory = transportFactory
    }

    func connect(to tv: LGTVDevice, forcePairing: Bool = false) async throws {
        onConnectionStateChange?(.connecting)
        logger.info("[connect] Attempting connection to \(tv.name) (\(tv.host))")

        let endpoints = [
            URL(string: "wss://\(tv.host):3001")!,
            URL(string: "ws://\(tv.host):3000")!
        ]

        var lastError: Error = LGWebOSError.notConnected

        for endpoint in endpoints {
            do {
                logger.info("[connect] Trying \(endpoint.absoluteString)")
                let transport = transportFactory(endpoint)
                try await transport.connect()
                self.transport = transport
                logger.info("[connect] WebSocket connected to \(endpoint.absoluteString)")
                startReceiveLoop()

                let existingClientKey = forcePairing ? nil : (try keyStore.clientKey(for: tv.id))
                logger.info("[connect] Registering (hasExistingKey: \(existingClientKey != nil))")
                let registeredKey = try await register(clientKey: existingClientKey)

                if let registeredKey {
                    try keyStore.saveClientKey(registeredKey, for: tv.id)
                    logger.info("[connect] Client key saved for TV id=\(tv.id)")
                }

                onConnectionStateChange?(.paired)
                logger.info("[connect] Paired and ready — \(tv.name) @ \(endpoint.absoluteString)")
                return
            } catch {
                logger.warning("[connect] Failed \(endpoint.absoluteString): \(error.localizedDescription)")
                lastError = error
                await disconnect()
            }
        }

        onConnectionStateChange?(.error(lastError.localizedDescription))
        onLastError?(lastError.localizedDescription)
        throw lastError
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil

        lock.lock()
        let currentTransport = transport
        transport = nil
        let continuations = pending.values
        pending.removeAll()
        pendingRegistrationID = nil
        lock.unlock()

        continuations.forEach { $0.resume(throwing: LGWebOSError.notConnected) }
        currentTransport?.disconnect()
        onConnectionStateChange?(.disconnected)
        logger.info("[disconnect] WebSocket disconnected")
    }

    func powerOff() async throws {
        _ = try await sendRequest(uri: "ssap://system/turnOff")
    }

    func volumeUp() async throws {
        _ = try await sendRequest(uri: "ssap://audio/volumeUp")
    }

    func volumeDown() async throws {
        _ = try await sendRequest(uri: "ssap://audio/volumeDown")
    }

    func toggleMute() async throws {
        // Query current mute state first, then send the inverse.
        let volResp = try await sendRequest(uri: "ssap://audio/getVolume")
        let currentMute = volResp.payload?["mute"]?.boolValue ?? false
        _ = try await sendRequest(
            uri: "ssap://audio/setMute",
            payload: ["mute": .bool(!currentMute)]
        )
    }

    func channelUp() async throws {
        _ = try await sendRequest(uri: "ssap://tv/channelUp")
    }

    func channelDown() async throws {
        _ = try await sendRequest(uri: "ssap://tv/channelDown")
    }

    func sendButton(_ name: String) async throws {
        _ = try await sendRequest(
            uri: "ssap://com.webos.service.networkinput/sendButton",
            payload: ["name": .string(name)]
        )
    }

    func launchApp(_ appId: String) async throws {
        _ = try await sendRequest(
            uri: "ssap://system.launcher/launch",
            payload: ["id": .string(appId)]
        )
    }

    func switchInput(_ inputId: String) async throws {
        _ = try await sendRequest(
            uri: "ssap://tv/switchInput",
            payload: ["inputId": .string(inputId)]
        )
    }

    func queryRuntimeState() async throws -> TVRuntimeState {
        var state = runtimeState

        if let response = try? await sendRequest(uri: "ssap://audio/getVolume"),
           let payload = response.payload {
            state.volume = payload["volume"]?.intValue
            state.isMuted = payload["mute"]?.boolValue
        }

        if let response = try? await sendRequest(uri: "ssap://com.webos.applicationManager/getForegroundAppInfo"),
           let payload = response.payload {
            state.foregroundAppId = payload["appId"]?.stringValue
        }

        if let response = try? await sendRequest(uri: "ssap://com.webos.service.tvpower/power/getPowerState"),
           let payload = response.payload,
           let stateObj = payload["state"]?.objectValue {
            state.powerState = stateObj["power"]?.stringValue
        }

        runtimeState = state
        onRuntimeState?(state)
        return state
    }

    // MARK: – Registration

    private func register(clientKey: String?) async throws -> String? {
        var payload: [String: JSONValue] = [
            "pairingType": .string("PROMPT"),
            "manifest": .object([
                "manifestVersion": .int(1),
                "appVersion": .string("1.0"),
                "signed": .object([
                    "created": .string("2024-01-01"),
                    "appId": .string("com.example.lgoledremote"),
                    "vendorId": .string("com.example")
                ]),
                "permissions": .array([
                    .string("LAUNCH"),
                    .string("LAUNCH_WEBAPP"),
                    .string("CONTROL_AUDIO"),
                    .string("CONTROL_INPUT_TEXT"),
                    .string("CONTROL_INPUT_JOYSTICK"),
                    .string("CONTROL_MOUSE_AND_KEYBOARD"),
                    .string("CONTROL_POWER"),
                    .string("READ_RUNNING_APPS"),
                    .string("READ_CURRENT_CHANNEL"),
                    .string("READ_TV_CHANNEL_LIST"),
                    .string("READ_INPUT_DEVICE_LIST"),
                    .string("READ_POWER_STATE")
                ])
            ])
        ]

        if let clientKey {
            payload["client-key"] = .string(clientKey)
        }

        let requestID = nextRequestID()
        let request = LGWebOSRequest(type: "register", id: requestID, uri: nil, payload: payload)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LGWebOSError.transport("Failed to encode registration request")
        }
        guard let transport = currentTransport else {
            throw LGWebOSError.notConnected
        }

        // Signal handle(response:) to skip the intermediate PROMPT "response" message
        // and keep the continuation alive until the final "registered" message arrives.
        lock.lock()
        pendingRegistrationID = requestID
        lock.unlock()

        defer {
            lock.lock()
            if pendingRegistrationID == requestID { pendingRegistrationID = nil }
            lock.unlock()
        }

        logger.info("[register] Sending registration (id: \(requestID), hasKey: \(clientKey != nil))")

        let response: LGWebOSResponse = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[requestID] = continuation
            lock.unlock()

            Task {
                do {
                    try await transport.send(text: text)
                    // Allow 60 s for the user to see and approve the TV pairing prompt.
                    self.scheduleTimeout(for: requestID, after: 60)
                } catch {
                    self.resolvePending(id: requestID, with: .failure(error))
                }
            }
        }

        guard response.type == "registered" else {
            throw LGWebOSError.authFailed(
                response.error ?? "Unexpected registration response type: \(response.type)")
        }

        let key = response.payload?["client-key"]?.stringValue
        logger.info("[register] Registered successfully. clientKey received: \(key != nil)")
        return key
    }

    // MARK: – Request / Response

    @discardableResult
    private func sendRequest(uri: String, payload: [String: JSONValue]? = nil) async throws -> LGWebOSResponse {
        try await sendRaw(type: "request", uri: uri, payload: payload)
    }

    private func sendRaw(type: String, uri: String?, payload: [String: JSONValue]?) async throws -> LGWebOSResponse {
        let requestID = nextRequestID()
        let request = LGWebOSRequest(type: type, id: requestID, uri: uri, payload: payload)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LGWebOSError.transport("Failed to encode request")
        }

        guard let transport = currentTransport else {
            throw LGWebOSError.notConnected
        }

        logger.debug("[send] → type=\(type) uri=\(uri ?? "nil") id=\(requestID)")

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[requestID] = continuation
            lock.unlock()

            Task {
                do {
                    try await transport.send(text: text)
                    self.scheduleTimeout(for: requestID, after: 10)
                } catch {
                    self.resolvePending(id: requestID, with: .failure(error))
                }
            }
        }
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    guard let transport = currentTransport else { break }
                    let text = try await transport.receive()
                    let response = try JSONDecoder().decode(LGWebOSResponse.self, from: Data(text.utf8))
                    handle(response: response)
                } catch {
                    if !Task.isCancelled {
                        logger.error("[receiveLoop] Error: \(error.localizedDescription). Disconnecting.")
                        onLastError?(error.localizedDescription)
                        onConnectionStateChange?(.disconnected)
                    }
                    break
                }
            }
        }
    }

    private func handle(response: LGWebOSResponse) {
        guard let id = response.id else {
            applyRuntimeStateIfPresent(from: response.payload)
            return
        }

        // The LG webOS PROMPT pairing flow sends two messages with the same request ID:
        //   1. {"type":"response", "payload":{"pairingType":"PROMPT"}}  – TV showing dialog
        //   2. {"type":"registered", "payload":{"client-key":"…"}}       – user approved
        // Do NOT resolve the continuation on step 1; keep it alive for step 2.
        lock.lock()
        let isRegistrationPrompt = (id == pendingRegistrationID && response.type == "response")
        lock.unlock()

        if isRegistrationPrompt {
            logger.info("[handle] TV is showing pairing prompt (id: \(id)) — waiting for user approval on TV screen…")
            return
        }

        logger.debug("[recv] ← type=\(response.type) id=\(id)")

        if resolvePending(id: id, with: .success(response)) {
            applyRuntimeStateIfPresent(from: response.payload)
            return
        }
        applyRuntimeStateIfPresent(from: response.payload)
    }

    private func applyRuntimeStateIfPresent(from payload: [String: JSONValue]?) {
        guard let payload else { return }

        var changed = false
        var state = runtimeState

        if let volume = payload["volume"]?.intValue {
            state.volume = volume
            changed = true
        }
        if let muted = payload["mute"]?.boolValue {
            state.isMuted = muted
            changed = true
        }
        if let appId = payload["appId"]?.stringValue {
            state.foregroundAppId = appId
            changed = true
        }

        if changed {
            runtimeState = state
            onRuntimeState?(state)
        }
    }

    private func nextRequestID() -> String {
        lock.lock()
        defer { lock.unlock() }
        requestCounter += 1
        return "req-\(requestCounter)"
    }

    private var currentTransport: WebSocketTransporting? {
        lock.lock()
        defer { lock.unlock() }
        return transport
    }

    @discardableResult
    private func resolvePending(id: String, with result: Result<LGWebOSResponse, Error>) -> Bool {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()

        guard let continuation else { return false }

        switch result {
        case .success(let response):
            continuation.resume(returning: response)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
        return true
    }

    private func scheduleTimeout(for requestID: String, after seconds: UInt64) {
        Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if resolvePending(id: requestID, with: .failure(LGWebOSError.timeout)) {
                logger.warning("[timeout] Request \(requestID) timed out after \(seconds)s")
            }
        }
    }
}
