import Foundation
import Network
import Security

// RawWebSocketTransport connects to ws://HOST:PORT/PATH using a plain TCP
// NWConnection and performs the WebSocket upgrade manually.
//
// Why not URLSessionWebSocketTask?
// URLSession negotiates "Sec-WebSocket-Extensions: permessage-deflate" by
// default. Many LG TV WebSocket servers (especially the /sys/remoteInputSocket
// endpoint) don't implement that extension and close the connection during the
// upgrade, leaving URLSession with a silently-dead socket. Third-party WebSocket
// libraries used by working LG TV clients (node-lgtv2, aiowebostv) never send
// extension headers and connect reliably.
//
// This class sends exactly the headers a minimal RFC-6455 client needs:
//   GET /path HTTP/1.1, Host, Upgrade, Connection, Sec-WebSocket-Key, Sec-WebSocket-Version
// Client frames are masked as required by §5.1.

final class RawWebSocketTransport: WebSocketTransporting {
    private let host: String
    private let port: UInt16
    private let path: String
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.sk.RawWebSocket", qos: .userInitiated)
    private var handshakeDone = false

    init(host: String, port: UInt16, path: String) {
        self.host = host
        self.port = port
        self.path = path
    }

    func connect() async throws {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.doHandshake(conn: conn, continuation: cont)
                case .failed(let err):
                    cont.resume(throwing: LGWebOSError.transport(err.localizedDescription))
                case .cancelled:
                    cont.resume(throwing: LGWebOSError.notConnected)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func doHandshake(conn: NWConnection, continuation: CheckedContinuation<Void, Error>) {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
        let wsKey = Data(keyBytes).base64EncodedString()

        let request =
            "GET \(path) HTTP/1.1\r\n" +
            "Host: \(host):\(port)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(wsKey)\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"

        conn.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                continuation.resume(throwing: LGWebOSError.transport(error.localizedDescription))
                return
            }
            self?.readHandshakeResponse(conn: conn, buffer: Data(), continuation: continuation)
        })
    }

    private func readHandshakeResponse(
        conn: NWConnection,
        buffer: Data,
        continuation: CheckedContinuation<Void, Error>
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isDone, error in
            if let error {
                continuation.resume(throwing: LGWebOSError.transport(error.localizedDescription))
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            guard let text = String(data: buf, encoding: .utf8) else {
                continuation.resume(throwing: LGWebOSError.invalidResponse)
                return
            }
            if text.contains("\r\n\r\n") {
                if text.hasPrefix("HTTP/1.1 101") || text.hasPrefix("HTTP/1.0 101") {
                    self?.handshakeDone = true
                    continuation.resume()
                } else {
                    let status = String(text.prefix(120))
                    continuation.resume(throwing: LGWebOSError.transport("WebSocket upgrade rejected: \(status)"))
                }
            } else if isDone {
                continuation.resume(throwing: LGWebOSError.transport("Connection closed during WebSocket handshake"))
            } else {
                self?.readHandshakeResponse(conn: conn, buffer: buf, continuation: continuation)
            }
        }
    }

    func send(text: String) async throws {
        guard let conn = connection, handshakeDone else { throw LGWebOSError.notConnected }
        let frame = Self.maskedTextFrame(text)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: LGWebOSError.transport(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    // The remote input socket is send-only; the TV sends nothing back.
    func receive() async throws -> String {
        try await Task.sleep(nanoseconds: UInt64.max)
        throw LGWebOSError.invalidResponse
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        handshakeDone = false
    }

    // RFC 6455 §5.2 – client frames must be masked with a random 4-byte key.
    private static func maskedTextFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var frame = Data()

        frame.append(0x81) // FIN=1, opcode=text(1)

        let len = payload.count
        if len <= 125 {
            frame.append(0x80 | UInt8(len))
        } else if len <= 65535 {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(len >> 8), UInt8(len & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }

        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        frame.append(contentsOf: mask)

        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ mask[i & 3])
        }

        return frame
    }
}
