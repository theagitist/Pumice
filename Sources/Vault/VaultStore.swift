import Foundation
import SwiftUI

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var resolvedURL: URL?
    @Published private(set) var status: Status = .idle

    private let defaultsKey = "app.example.Pumice.vaultBookmark"

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
        resolvedURL = nil
        status = .idle
    }
}
