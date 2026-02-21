import XCTest
@testable import LGOLEDRemote

final class LGWebOSClientTests: XCTestCase {
    func testPairAuthSavesClientKey() async throws {
        let store = MockClientKeyStore()
        let transport = MockWebSocketTransport()
        let client = LGWebOSClient(
            keyStore: store,
            logger: ConsoleLogger(),
            transportFactory: { _ in transport }
        )

        transport.onSend = { text in
            let req = try JSONDecoder().decode(LGWebOSRequest.self, from: Data(text.utf8))
            if req.type == "register" {
                return """
                {"type":"registered","id":"\(req.id)","payload":{"client-key":"abc123"}}
                """
            }
            return """
            {"type":"response","id":"\(req.id)","payload":{}}
            """
        }

        let tv = LGTVDevice(id: "tv1", name: "Living Room", host: "192.168.1.10", port: 3000, macAddress: nil)
        try await client.connect(to: tv, forcePairing: false)

        XCTAssertEqual(try store.clientKey(for: "tv1"), "abc123")
    }

    func testCommandRoutingCorrelation() async throws {
        let store = MockClientKeyStore()
        let transport = MockWebSocketTransport()
        let client = LGWebOSClient(
            keyStore: store,
            logger: ConsoleLogger(),
            transportFactory: { _ in transport }
        )

        transport.onSend = { text in
            let req = try JSONDecoder().decode(LGWebOSRequest.self, from: Data(text.utf8))
            if req.type == "register" {
                return """
                {"type":"registered","id":"\(req.id)","payload":{"client-key":"k"}}
                """
            }
            if req.uri == "ssap://audio/volumeUp" {
                return """
                {"type":"response","id":"\(req.id)","payload":{"returnValue":true}}
                """
            }
            return """
            {"type":"response","id":"\(req.id)","payload":{}}
            """
        }

        let tv = LGTVDevice(id: "tv2", name: "Bedroom", host: "192.168.1.11", port: 3000, macAddress: nil)
        try await client.connect(to: tv, forcePairing: false)
        try await client.volumeUp()
    }
}

private final class MockWebSocketTransport: WebSocketTransporting {
    var onSend: ((String) throws -> String)?
    private var queue: [String] = []

    func connect() async throws {}
    func disconnect() {}

    func send(text: String) async throws {
        if let response = try onSend?(text) {
            queue.append(response)
        }
    }

    func receive() async throws -> String {
        let start = Date()
        while queue.isEmpty {
            if Date().timeIntervalSince(start) > 1.0 {
                throw LGWebOSError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return queue.removeFirst()
    }
}

private final class MockClientKeyStore: ClientKeyStore {
    private var storage: [String: String] = [:]

    func clientKey(for tvID: String) throws -> String? {
        storage[tvID]
    }

    func saveClientKey(_ key: String, for tvID: String) throws {
        storage[tvID] = key
    }

    func removeClientKey(for tvID: String) throws {
        storage.removeValue(forKey: tvID)
    }
}
