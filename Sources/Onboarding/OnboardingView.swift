import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var vault: VaultStore
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.secondary)

            Text("Pumice")
                .font(.largeTitle.weight(.semibold))

            VStack(spacing: 12) {
                Text("Pick a folder. Pumice treats it as your vault — every PDF inside becomes a tap-to-open document.")
                    .multilineTextAlignment(.center)
                Text("Edits are written back into the PDF itself, with a .bak safety copy alongside. Nothing leaves your device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 520)

            statusBanner

            Button {
                showingPicker = true
            } label: {
                Label("Choose vault…", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingPicker) {
            VaultPicker(
                onPick: { url in
                    showingPicker = false
                    guard url.startAccessingSecurityScopedResource() else {
                        return
                    }
                    vault.adopt(pickedURL: url)
                },
                onCancel: { showingPicker = false }
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch vault.status {
        case .staleBookmark:
            Label("Your previous vault has moved or is no longer reachable. Pick it again to continue.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .accessDenied:
            Label("Permission to read the vault was denied. Re-pick the folder to grant access.",
                  systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .error(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        case .idle, .open:
            EmptyView()
        }
    }
}
