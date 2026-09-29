import SwiftUI

struct DeveloperCommandCenterView: View {
    @ObservedObject private var registry = SuperNotchFeatureRegistry.shared
    @StateObject private var monitor = SuperNotchSystemMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer Command Center")
                        .font(.title2.weight(.semibold))
                    Text("Fast signals and shortcuts without leaving SuperNotch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if registry.isEnabled(.systemPulse) {
                HStack(spacing: 10) {
                    metric("CPU", value: monitor.snapshot.cpuPercent, icon: "cpu")
                    metric("Memory", value: monitor.snapshot.memoryPercent, icon: "memorychip")
                    metric("Disk", value: monitor.snapshot.diskPercent, icon: "internaldrive")
                }
            }

            if registry.isEnabled(.quickLinks) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("QUICK LINKS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(SuperNotchQuickLink.allCases) { link in
                            Link(destination: link.url) {
                                Label(link.title, systemImage: link.icon)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                monitor.refresh()
            }
        }
    }

    private func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(value)%")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            ProgressView(value: Double(value), total: 100)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

struct SuperNotchFeatureSettingsView: View {
    @ObservedObject private var registry = SuperNotchFeatureRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SuperNotchFeatureID.allCases) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(feature.title)
                                .font(.system(size: 13, weight: .medium))
                            if feature.isCore {
                                Text("CORE")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(feature.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { registry.isEnabled(feature) },
                        set: { registry.setEnabled(feature, enabled: $0) }
                    ))
                    .labelsHidden()
                }
                .padding(.vertical, 4)

                if feature.id != SuperNotchFeatureID.allCases.last?.id {
                    Divider()
                }
            }
        }
    }
}
