import Foundation
import SwiftUI

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var resolvedURL: URL?
    @Published private(set) var status: Status = .idle
    /// Path of the most recently opened PDF, relative to `resolvedURL`.
    /// Persisted across app launches so the reader can restore the last
    /// document automatically.
    @Published private(set) var lastOpenedRelativePath: String?

    // Derive UserDefaults keys from the runtime bundle identifier so
    // the reverse-DNS prefix doesn't have to be hard-coded in source
    // (per local build setup, the prefix is configured in
    // Config/Local.xcconfig and isn't checked into the repo).
    private let defaultsKey = "\(Bundle.main.bundleIdentifier ?? "Pumice").vaultBookmark"
    private let lastOpenedKey = "\(Bundle.main.bundleIdentifier ?? "Pumice").lastOpenedPDF"

    enum Status: Equatable {
        case idle
        case open
        case staleBookmark
        case accessDenied
        case error(String)
    }

    func resolveOnLaunch() async {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                status = .staleBookmark
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                status = .accessDenied
                return
            }
            resolvedURL = url
            status = .open
            lastOpenedRelativePath = UserDefaults.standard.string(forKey: lastOpenedKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            status = .error(error.localizedDescription)
        }
    }

    func adopt(pickedURL url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: defaultsKey)
            resolvedURL = url
            status = .open
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func forget() {
        if let url = resolvedURL {
            url.stopAccessingSecurityScopedResource()
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: lastOpenedKey)
        resolvedURL = nil
        lastOpenedRelativePath = nil
        status = .idle
    }

    /// Remember the PDF the user just opened so we can restore it on next
    /// launch. `pdfURL` is stored as a path relative to the vault root; we
    /// don't persist absolute URLs because the security-scoped bookmark
    /// is for the vault, not individual files inside it.
    func rememberOpenedPDF(_ pdfURL: URL) {
        guard let vaultURL = resolvedURL else { return }
        let vaultPath = vaultURL.standardizedFileURL.path
        let pdfPath = pdfURL.standardizedFileURL.path
        guard pdfPath.hasPrefix(vaultPath) else { return }
        let relative = String(pdfPath.dropFirst(vaultPath.count)).drop(while: { $0 == "/" })
        let relativeString = String(relative)
        guard !relativeString.isEmpty else { return }
        UserDefaults.standard.set(relativeString, forKey: lastOpenedKey)
        lastOpenedRelativePath = relativeString
    }

    /// Resolve the last-opened relative path against the current vault.
    /// Returns nil if no path is remembered or the file no longer exists.
    func resolveLastOpened() -> URL? {
        guard let vaultURL = resolvedURL,
              let relative = lastOpenedRelativePath,
              !relative.isEmpty
        else { return nil }
        let candidate = vaultURL.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}
