import AppKit
import Foundation

@MainActor
final class SuperNotchUpdateController {
    static let shared = SuperNotchUpdateController()

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/budimanr3101/supernotch/releases/latest")!
    private let session: URLSession
    private var alert: NSAlert?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    func checkForUpdates() {
        let current = currentVersion
        Task {
            do {
                var request = URLRequest(url: latestReleaseURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("SuperNotch/\(current)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateError.releaseUnavailable
                }

                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard isNewer(latest, than: current) else {
                    showUpToDate(version: current)
                    return
                }

                guard let dmg = release.assets.first(where: { $0.name == "SuperNotch.dmg" }) else {
                    throw UpdateError.missingDMG
                }
                showUpdateAvailable(current: current, latest: latest, downloadURL: dmg.browserDownloadURL)
            } catch {
                showError(error)
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func showUpToDate(version: String) {
        let alert = NSAlert()
        alert.messageText = "SuperNotch is up to date"
        alert.informativeText = "You're running SuperNotch \(version)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    private func showUpdateAvailable(current: String, latest: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = "SuperNotch \(latest) is available"
        alert.informativeText = "You're running \(current). Download the latest release and replace SuperNotch in Applications."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        self.alert = alert

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        self.alert = nil
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    private func present(_ alert: NSAlert) {
        self.alert = alert
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        self.alert = nil
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum UpdateError: LocalizedError {
    case releaseUnavailable
    case missingDMG

    var errorDescription: String? {
        switch self {
        case .releaseUnavailable:
            return "The latest SuperNotch release could not be reached. Check your internet connection and try again."
        case .missingDMG:
            return "The latest GitHub release does not contain SuperNotch.dmg."
        }
    }
}
