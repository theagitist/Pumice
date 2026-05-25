import SwiftUI

/// Shown while `VaultStore.resolveOnLaunch()` is in flight, so the
/// first frame after the iOS launch image is the app's own branded
/// loader instead of a blank white screen or a flash of onboarding
/// while the vault bookmark is being resolved.
///
/// Background is set to the same `#161616` near-black that the icon
/// art itself sits on, so the icon visually melts into the page
/// instead of floating on a contrasting field. `.preferredColorScheme(.dark)`
/// keeps text and the spinner in light-mode-on-dark colors regardless
/// of the device appearance setting, since the background is fixed.
struct LaunchView: View {
    /// `RGB(22, 22, 22)` — sampled from the icon's corners.
    private static let iconBackground = Color(
        red: 22.0 / 255.0,
        green: 22.0 / 255.0,
        blue: 22.0 / 255.0
    )

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("PumiceLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 220, height: 220)

            Text("Pumice")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .tracking(0.5)

            Text("Local-first PDF annotation")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)

                Text("Loading vault…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.iconBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
