import SwiftUI

@main
struct PumiceApp: App {
    @StateObject private var vault = VaultStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vault)
                .task { await vault.resolveOnLaunch() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var vault: VaultStore

    var body: some View {
        Group {
            if let url = vault.resolvedURL {
                VaultBrowserView(vaultURL: url)
            } else {
                OnboardingView()
            }
        }
    }
}
