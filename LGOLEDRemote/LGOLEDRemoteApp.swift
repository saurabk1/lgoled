import SwiftUI

@main
struct LGOLEDRemoteApp: App {
    @StateObject private var viewModel: TVControlViewModel

    init() {
        let logger = ConsoleLogger()
        let keyStore = KeychainStore(service: "com.example.LGOLEDRemote")
        let discovery = DiscoveryService(logger: logger)
        let client = LGWebOSClient(keyStore: keyStore, logger: logger)
        let wol = WakeOnLANService(logger: logger)

        _viewModel = StateObject(
            wrappedValue: TVControlViewModel(
                discoveryService: discovery,
                client: client,
                wolService: wol,
                keyStore: keyStore
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
