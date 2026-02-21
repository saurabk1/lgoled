import XCTest
@testable import LGOLEDRemote

@MainActor
final class TVControlViewModelTests: XCTestCase {
    func testStateTransitionsDiscoveryToConnected() async throws {
        let discovery = MockDiscoveryService()
        let client = MockClient()
        let wol = MockWOL()
        let keyStore = MockStore()

        let vm = TVControlViewModel(discoveryService: discovery, client: client, wolService: wol, keyStore: keyStore)

        vm.startDiscovery()
        XCTAssertEqual(vm.connectionState, .discovering)

        let tv = LGTVDevice(id: "tv", name: "Living Room", host: "192.168.1.20", port: 3000, macAddress: nil)
        discovery.onDevicesUpdated?([tv])
        vm.selectedTVID = tv.id
        vm.connectSelectedTV()

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.connectionState, .paired)
    }
}

private final class MockDiscoveryService: DiscoveryServicing {
    var onDevicesUpdated: (([LGTVDevice]) -> Void)?
    var onStatusChanged: ((String) -> Void)?
    func startDiscovery() { onStatusChanged?("Discovering") }
    func stopDiscovery() {}
}

private final class MockClient: LGWebOSControlling {
    var onConnectionStateChange: ((ConnectionState) -> Void)?
    var onRuntimeState: ((TVRuntimeState) -> Void)?
    var onLastError: ((String) -> Void)?

    func connect(to tv: LGTVDevice, forcePairing: Bool) async throws {
        onConnectionStateChange?(.connecting)
        onConnectionStateChange?(.paired)
    }

    func disconnect() async { onConnectionStateChange?(.disconnected) }
    func powerOff() async throws {}
    func volumeUp() async throws {}
    func volumeDown() async throws {}
    func toggleMute() async throws {}
    func channelUp() async throws {}
    func channelDown() async throws {}
    func sendButton(_ name: String) async throws {}
    func launchApp(_ appId: String) async throws {}
    func switchInput(_ inputId: String) async throws {}
    func queryRuntimeState() async throws -> TVRuntimeState { TVRuntimeState() }
}

private final class MockWOL: WakeOnLANServicing {
    func wake(macAddress: String) async throws {}
}

private final class MockStore: ClientKeyStore {
    func clientKey(for tvID: String) throws -> String? { nil }
    func saveClientKey(_ key: String, for tvID: String) throws {}
    func removeClientKey(for tvID: String) throws {}
}
