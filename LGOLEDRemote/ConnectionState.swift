import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case discovering
    case connecting
    case paired
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .discovering: return "Discovering"
        case .connecting: return "Connecting"
        case .paired: return "Connected"
        case .error(let message): return "Error: \(message)"
        }
    }

    var isConnected: Bool {
        if case .paired = self { return true }
        return false
    }
}
