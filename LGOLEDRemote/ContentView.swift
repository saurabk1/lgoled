import SwiftUI

struct ContentView: View {
    @StateObject var viewModel: TVControlViewModel

    var body: some View {
        TabView {
            RemoteView(viewModel: viewModel)
                .tabItem {
                    Label("Remote", systemImage: "tv")
                }

            SettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .task {
            viewModel.startDiscovery()
        }
    }
}
