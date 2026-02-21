import SwiftUI

struct RemoteView: View {
    @ObservedObject var viewModel: TVControlViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    tvPicker
                    statusCard
                    dpad
                    controlsGrid
                }
                .padding()
            }
            .navigationTitle("LG Remote")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { viewModel.refreshRuntimeState() }
                }
            }
        }
    }

    private var tvPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TV")
                .font(.headline)

            Picker("TV Selector", selection: $viewModel.selectedTVID) {
                ForEach(viewModel.discoveredTVs) { tv in
                    Text(tv.name).tag(Optional(tv.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("Discover") { viewModel.startDiscovery() }
                    .buttonStyle(.bordered)
                Button("Connect") { viewModel.connectSelectedTV() }
                    .buttonStyle(.borderedProminent)
                Button("Disconnect") { viewModel.disconnect() }
                    .buttonStyle(.bordered)
            }

            HStack {
                TextField("TV IP (e.g. 192.168.1.50)", text: $viewModel.manualTVHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Manual TV IP")

                Button("Connect IP") {
                    viewModel.connectManualIP()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status: \(viewModel.connectionState.label)")
                .font(.subheadline)
            Text("Discovery: \(viewModel.discoveryStatus)")
                .font(.caption)
            Text("Volume: \(viewModel.runtimeState.volume.map(String.init) ?? "-")")
                .font(.caption)
            Text("Muted: \(viewModel.runtimeState.isMuted == true ? "Yes" : "No")")
                .font(.caption)
            Text("App: \(viewModel.runtimeState.foregroundAppId ?? "-")")
                .font(.caption)
            if let error = viewModel.lastErrorMessage {
                Text("Last Error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var dpad: some View {
        VStack(spacing: 8) {
            Text("Navigation").font(.headline)

            Button("↑") { viewModel.sendButton("UP") }
                .font(.title2)
                .frame(width: 72, height: 54)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("D-pad Up")

            HStack(spacing: 8) {
                Button("←") { viewModel.sendButton("LEFT") }
                    .frame(width: 72, height: 54)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("D-pad Left")

                Button("OK") { viewModel.sendButton("ENTER") }
                    .frame(width: 90, height: 54)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("D-pad OK")

                Button("→") { viewModel.sendButton("RIGHT") }
                    .frame(width: 72, height: 54)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("D-pad Right")
            }

            Button("↓") { viewModel.sendButton("DOWN") }
                .font(.title2)
                .frame(width: 72, height: 54)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("D-pad Down")
        }
    }

    private var controlsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            Button("Vol +") { viewModel.volumeUp() }
            Button("Vol -") { viewModel.volumeDown() }
            Button("Mute") { viewModel.mute() }
            Button("Power Off") { viewModel.powerOff() }
            Button("Ch +") { viewModel.channelUp() }
            Button("Ch -") { viewModel.channelDown() }
            Button("Home") { viewModel.sendButton("HOME") }
            Button("Back") { viewModel.sendButton("BACK") }
            Button("Netflix") { viewModel.launchNetflix() }
            Button("HDMI 1") { viewModel.switchToHDMI1() }
            Button("Wake (WOL)") { viewModel.wakeSelectedTV() }
        }
        .buttonStyle(.borderedProminent)
    }
}
