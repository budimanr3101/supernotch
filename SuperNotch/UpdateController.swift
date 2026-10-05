import AppKit
import Foundation
import Sparkle

@MainActor
final class SuperNotchUpdateController: ObservableObject {
    static let shared = SuperNotchUpdateController()

    let updaterController: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

    private var observations: [NSKeyValueObservation] = []

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = updaterController.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates

        observations.append(updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        })
        observations.append(updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
        })
        observations.append(updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates }
        })
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkForUpdates() {
        Task {
            await checkGitHubRelease()
        }
    }

    private func checkGitHubRelease() async {
        guard let url = URL(string: "https://api.github.com/repos/budimanr3101/supernotch/releases/latest") else {
            return
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("SuperNotch/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateCheckError.invalidResponse
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            guard latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending else {
                showUpToDateAlert()
                return
            }

            guard let dmg = release.assets.first(where: { $0.name == "SuperNotch.dmg" }) else {
                throw UpdateCheckError.missingDMG
            }

            showUpdateAlert(version: latestVersion, downloadURL: dmg.browserDownloadURL)
        } catch {
            // Keep Sparkle as a secondary path for signed-feed deployments.
            // If the GitHub release check fails, let Sparkle surface its native result.
            updaterController.checkForUpdates(nil)
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "SuperNotch is up to date"
        alert.informativeText = "You're running SuperNotch \(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showUpdateAlert(version: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = "SuperNotch \(version) is available"
        alert.informativeText = "Download the latest official DMG from GitHub Releases, then replace SuperNotch in Applications."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard updaterController.updater.allowsAutomaticUpdates else { return }
        updaterController.updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = enabled
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

private enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case missingDMG

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The latest GitHub release could not be read."
        case .missingDMG:
            return "The latest GitHub release does not contain SuperNotch.dmg."
        }
    }
}
