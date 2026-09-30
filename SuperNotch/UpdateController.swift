import AppKit
import Sparkle
import SwiftUI

@MainActor
final class SuperNotchUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SuperNotchUpdateController()

    @Published private(set) var isChecking = false
    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var lastErrorMessage: String?

    private var started = false

    private lazy var standardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        super.init()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var canCheckForUpdates: Bool {
        started && standardUpdaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { standardUpdaterController.updater.automaticallyChecksForUpdates }
        set {
            standardUpdaterController.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { standardUpdaterController.updater.automaticallyDownloadsUpdates }
        set {
            standardUpdaterController.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    var allowsAutomaticUpdates: Bool {
        standardUpdaterController.updater.allowsAutomaticUpdates
    }

    var lastUpdateCheckDate: Date? {
        standardUpdaterController.updater.lastUpdateCheckDate
    }

    func start() {
        guard !started else { return }
        started = true
        standardUpdaterController.startUpdater()
        objectWillChange.send()
        NSLog("[SuperNotch] Sparkle OTA updater started")
    }

    func checkForUpdates() {
        if !started { start() }
        guard standardUpdaterController.updater.canCheckForUpdates else { return }
        isChecking = true
        lastErrorMessage = nil
        standardUpdaterController.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable = true
        latestVersion = item.displayVersionString
        isChecking = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        updateAvailable = false
        latestVersion = nil
        isChecking = false
        lastErrorMessage = nil
        objectWillChange.send()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        isChecking = false
        if let error {
            lastErrorMessage = error.localizedDescription
        }
        objectWillChange.send()
    }
}

struct SuperNotchUpdateSettingsView: View {
    @ObservedObject private var updates = SuperNotchUpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusCard
            preferencesCard
            securityNote
        }
        .onAppear {
            updates.start()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: updates.updateAvailable ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    if let latest = updates.latestVersion, updates.updateAvailable {
                        Text("SuperNotch \(latest) is available")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Sparkle will download, verify, install, and relaunch SuperNotch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("SuperNotch \(updates.currentVersion)")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Build \(updates.currentBuild) · Secure OTA updates")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(updates.isChecking ? "Checking…" : "Check") {
                    updates.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .disabled(updates.isChecking || !updates.canCheckForUpdates)
            }

            if let error = updates.lastErrorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var preferencesCard: some View {
        VStack(spacing: 0) {
            settingsRow(title: "Automatically check for updates", subtitle: "Check the official SuperNotch update feed in the background.") {
                Toggle("", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.automaticallyChecksForUpdates = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Divider().padding(.leading, 16)

            settingsRow(title: "Automatically download updates", subtitle: "Download verified updates so Install & Relaunch is ready faster.") {
                Toggle("", isOn: Binding(
                    get: { updates.automaticallyDownloadsUpdates },
                    set: { updates.automaticallyDownloadsUpdates = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!updates.allowsAutomaticUpdates)
            }

            if let checked = updates.lastUpdateCheckDate {
                Divider().padding(.leading, 16)
                HStack {
                    Text("Last checked")
                    Spacer()
                    Text(checked, style: .relative)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var securityNote: some View {
        Label(
            "Updates are delivered over HTTPS and verified with SuperNotch's Ed25519 update key before installation.",
            systemImage: "checkmark.shield.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func settingsRow<Accessory: View>(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            accessory()
        }
        .padding(16)
    }
}
