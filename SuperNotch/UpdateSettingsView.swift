import SwiftUI

struct SuperNotchUpdateSettingsView: View {
    @ObservedObject private var updater = SuperNotchUpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            updateCard

            VStack(spacing: 0) {
                settingsRow(title: "Check for Updates") {
                    Button("Check") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.canCheckForUpdates)
                }

                Divider()

                settingsRow(title: "Automatically check for updates") {
                    Toggle("", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Divider()

                settingsRow(title: "Automatically download updates") {
                    Toggle("", isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates },
                        set: { updater.setAutomaticallyDownloadsUpdates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!updater.automaticallyChecksForUpdates)
                }
            }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )

            Text("SuperNotch uses Sparkle to securely download, verify, install, and relaunch app updates. Release notes and installation progress are shown by the native updater window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var updateCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("SuperNotch \(updater.currentVersion)")
                    .font(.system(size: 16, weight: .semibold))
                Text("Ready for over-the-air updates")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!updater.canCheckForUpdates)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private func settingsRow<Accessory: View>(
        title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            accessory()
        }
        .frame(minHeight: 50)
    }
}
