import Foundation
import SwiftUI
import Combine

@MainActor
final class TVControlViewModel: ObservableObject {
    @Published var discoveredTVs: [LGTVDevice] = []
    @Published var selectedTVID: String?
    @Published var manualTVHost: String = ""
    @Published var connectionState: ConnectionState = .disconnected
    @Published var runtimeState = TVRuntimeState()
    @Published var lastErrorMessage: String?
    @Published var discoveryStatus: String = "Idle"
    @Published var diagnosticsSocketStatus: String = "Disconnected"

    private let discoveryService: DiscoveryServicing
    private let client: LGWebOSControlling
    private let wolService: WakeOnLANServicing
    private let keyStore: ClientKeyStore

    private var reconnectTask: Task<Void, Never>?

    // Persist the last successfully-connected TV so the app auto-connects on relaunch
    // without needing SSDP/Bonjour discovery to succeed.
    private static let savedTVKey = "savedTV"

    private func loadSavedTV() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedTVKey),
              let tv = try? JSONDecoder().decode(LGTVDevice.self, from: data) else { return }
        if !discoveredTVs.contains(where: { $0.id == tv.id }) {
            discoveredTVs.append(tv)
            discoveredTVs.sort { $0.name < $1.name }
        }
        if selectedTVID == nil { selectedTVID = tv.id }
    }

    private func saveTV(_ tv: LGTVDevice) {
        guard let data = try? JSONEncoder().encode(tv) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedTVKey)
    }

    init(
        discoveryService: DiscoveryServicing,
        client: LGWebOSControlling,
        wolService: WakeOnLANServicing,
        keyStore: ClientKeyStore
    ) {
        self.discoveryService = discoveryService
        self.client = client
        self.wolService = wolService
        self.keyStore = keyStore

        self.discoveryService.onDevicesUpdated = { [weak self] devices in
            Task { @MainActor in
                self?.discoveredTVs = devices
                if self?.selectedTVID == nil {
                    self?.selectedTVID = devices.first?.id
                }
            }
        }

        self.discoveryService.onStatusChanged = { [weak self] status in
            Task { @MainActor in self?.discoveryStatus = status }
        }

        self.client.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                self?.connectionState = state
                self?.diagnosticsSocketStatus = state.label
                if state == .paired, let tv = self?.selectedTV {
                    self?.saveTV(tv)   // persist so next launch skips discovery
                }
                // Only auto-reconnect on clean disconnects, not on explicit errors.
                if state == .disconnected {
                    self?.scheduleReconnect()
                }
            }
        }

        self.client.onRuntimeState = { [weak self] state in
            Task { @MainActor in self?.runtimeState = state }
        }

        self.client.onLastError = { [weak self] error in
            Task { @MainActor in self?.lastErrorMessage = error }
        }
    }

    func startDiscovery() {
        // Restore the last-known TV immediately so the picker is populated
        // and auto-connect fires before SSDP/Bonjour finishes (or fails).
        loadSavedTV()
        if let tv = selectedTV {
            connectSelectedTV()
            discoveryStatus = "Auto-connecting to \(tv.name)…"
        }
        connectionState = .discovering
        discoveryService.startDiscovery()
    }

    func stopDiscovery() {
        discoveryService.stopDiscovery()
    }

    func connectSelectedTV(forcePairing: Bool = false) {
        guard let tv = selectedTV else { return }
        reconnectTask?.cancel()
        reconnectTask = nil

        Task { @MainActor in
            do {
                try await client.connect(to: tv, forcePairing: forcePairing)
                _ = try? await client.queryRuntimeState()
            } catch {
                lastErrorMessage = error.localizedDescription
                connectionState = .error(error.localizedDescription)
            }
        }
    }

    func connectManualIP() {
        let host = manualTVHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            lastErrorMessage = "Enter a TV IP address first."
            return
        }

        let manualDevice = LGTVDevice(
            id: "manual-\(host)",
            name: "LG TV (\(host))",
            host: host,
            port: 3000,
            macAddress: nil
        )

        if !discoveredTVs.contains(where: { $0.id == manualDevice.id }) {
            discoveredTVs.append(manualDevice)
            discoveredTVs.sort { $0.name < $1.name }
        }

        selectedTVID = manualDevice.id
        connectSelectedTV()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { await client.disconnect() }
    }

    func rePair() {
        connectSelectedTV(forcePairing: true)
    }

    func forgetSelectedTVAuth() {
        guard let tv = selectedTV else { return }
        do {
            try keyStore.removeClientKey(for: tv.id)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func wakeSelectedTV() {
        guard let mac = selectedTV?.macAddress else {
            lastErrorMessage = "MAC address not available from discovery. Wake-on-LAN may not be possible for this model."
            return
        }
        Task {
            do {
                try await wolService.wake(macAddress: mac)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func refreshRuntimeState() {
        Task {
            do {
                runtimeState = try await client.queryRuntimeState()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func sendButton(_ button: String) {
        Task {
            do {
                try await client.sendButton(button)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func volumeUp() {
        Task {
            do {
                try await client.volumeUp()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func volumeDown() {
        Task {
            do {
                try await client.volumeDown()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func mute() {
        Task {
            do {
                try await client.toggleMute()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func channelUp() {
        Task {
            do {
                try await client.channelUp()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func channelDown() {
        Task {
            do {
                try await client.channelDown()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func powerOff() {
        Task {
            do {
                try await client.powerOff()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func launchNetflix() {
        Task {
            do {
                try await client.launchApp("netflix")
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func switchToHDMI1() {
        Task {
            do {
                try await client.switchInput("HDMI_1")
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    var selectedTV: LGTVDevice? {
        discoveredTVs.first(where: { $0.id == selectedTVID })
    }

    private func scheduleReconnect() {
        guard let tv = selectedTV else { return }
        reconnectTask?.cancel()

        // Call client.connect() directly to avoid connectSelectedTV() cancelling
        // reconnectTask (itself), which would break exponential backoff.
        reconnectTask = Task { [weak self] in
            for attempt in 1...5 {
                guard let self else { return }
                if Task.isCancelled { return }

                let waitSeconds = UInt64(pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: waitSeconds * 1_000_000_000)
                if Task.isCancelled { return }

                do {
                    try await self.client.connect(to: tv, forcePairing: false)
                    _ = try? await self.client.queryRuntimeState()
                    await MainActor.run { self.lastErrorMessage = nil }
                    return  // successfully reconnected
                } catch {
                    await MainActor.run {
                        self.lastErrorMessage =
                            "Reconnect attempt \(attempt)/5 failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
