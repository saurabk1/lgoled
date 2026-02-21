import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: TVControlViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing") {
                    Button("Re-pair Current TV") {
                        viewModel.rePair()
                    }
                    Button("Forget Saved TV Auth") {
                        viewModel.forgetSelectedTVAuth()
                    }
                }

                Section("Diagnostics") {
                    LabeledContent("Connection", value: viewModel.connectionState.label)
                    LabeledContent("Discovery", value: viewModel.discoveryStatus)
                    LabeledContent("Socket", value: viewModel.diagnosticsSocketStatus)
                    LabeledContent("Power", value: viewModel.runtimeState.powerState ?? "-")
                    if let error = viewModel.lastErrorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Network Tips") {
                    Text("Use a physical iPhone on the same Wi-Fi as the TV.")
                    Text("Approve the TV pairing prompt when connecting the first time.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
