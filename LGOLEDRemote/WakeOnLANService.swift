import Foundation
import Network

protocol WakeOnLANServicing {
    func wake(macAddress: String) async throws
}

final class WakeOnLANService: WakeOnLANServicing {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func wake(macAddress: String) async throws {
        let macBytes = try Self.parseMAC(macAddress)
        let packet = Self.magicPacket(for: macBytes)

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let connection = NWConnection(host: "255.255.255.255", port: 9, using: params)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: ())
                        }
                        connection.cancel()
                    })
                case .failed(let error):
                    continuation.resume(throwing: error)
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }

        logger.info("WOL packet sent")
    }

    private static func parseMAC(_ mac: String) throws -> [UInt8] {
        let separators = CharacterSet(charactersIn: ":-")
        let parts = mac.components(separatedBy: separators).filter { !$0.isEmpty }
        guard parts.count == 6 else {
            throw LGWebOSError.transport("Invalid MAC address format.")
        }
        let bytes = try parts.map { part -> UInt8 in
            guard let value = UInt8(part, radix: 16) else {
                throw LGWebOSError.transport("Invalid MAC address format.")
            }
            return value
        }
        return bytes
    }

    private static func magicPacket(for mac: [UInt8]) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: mac)
        }
        return packet
    }
}
